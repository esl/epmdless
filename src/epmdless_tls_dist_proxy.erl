%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2011-2016. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(epmdless_tls_dist_proxy).


-export([listen/2, accept/2, connect/3, get_tcp_address/1]).
-export([init/1, start_link/0, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include_lib("kernel/include/net_address.hrl").

-include("epmdless.hrl").

-record(state, 
	{listen,
	 accept_loop
	}).

-define(PPRE, 4).
-define(PPOST, 4).

%% this macro only exists in OTP-21 and above, where ssl_accept/2 is deprecated
-ifdef(OTP_RELEASE).
-define(ssl_accept(TCPSocket, TLSOpts), ssl:handshake(TCPSocket, TLSOpts)).
-else.
-define(ssl_accept(TCPSocket, TLSOpts), ssl:ssl_accept(TCPSocket, TLSOpts)).
-endif.

%%====================================================================
%% Internal application API
%%====================================================================

listen(Driver, Name) ->
    gen_server:call(?MODULE, {listen, Driver, Name}, infinity).

accept(Driver, Listen) ->
    gen_server:call(?MODULE, {accept, Driver, Listen}, infinity).

connect(Driver, Ip, Port) ->
    gen_server:call(?MODULE, {connect, Driver, Ip, Port}, infinity).


do_listen(Options) ->
    {First,Last} = case application:get_env(kernel,inet_dist_listen_min) of
                        {ok,N} when is_integer(N) ->
                            case application:get_env(kernel,
                                                    inet_dist_listen_max) of
                               {ok,M} when is_integer(M) ->
                                   {N,M};
                               _ ->
                                   {N,N}
                            end;
                        _ ->
                            {0,0}
                   end,
    do_listen(First, Last, listen_options([{backlog,128}|Options])).

do_listen(First,Last,_) when First > Last ->
    {error,eaddrinuse};
do_listen(First,Last,Options) ->
    case gen_tcp:listen(First, Options) of
        {error, eaddrinuse} ->
            do_listen(First+1,Last,Options);
        Other ->
            Other
    end.

listen_options(Opts0) ->
    Opts1 =
        case application:get_env(kernel, inet_dist_use_interface) of
            {ok, Ip} ->
                [{ip, Ip} | Opts0];
            _ ->
                Opts0
        end,
    case application:get_env(kernel, inet_dist_listen_options) of
        {ok,ListenOpts} ->
            ListenOpts ++ Opts1;
        _ ->
            Opts1
    end.

connect_options(Opts) ->
    case application:get_env(kernel, inet_dist_connect_options) of
	{ok,ConnectOpts} ->
	    lists:ukeysort(1, ConnectOpts ++ Opts);
	_ ->
	    Opts
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

start_link() ->
    spawn(fun() -> application:ensure_all_started(ssl) end),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(priority, max),
    {ok, #state{}}.

handle_call({listen, Driver, Name}, _From, State) ->
    case gen_tcp:listen(0, [{active, false}, {packet,?PPRE}, {ip, loopback}]) of
	{ok, Socket} ->
	    {ok, World} = do_listen([{active, false}, binary, {packet,?PPRE}, {reuseaddr, true},
                                     Driver:family()]),
	    {ok, TcpAddress} = get_tcp_address(Socket),
	    {ok, WorldTcpAddress} = get_tcp_address(World),
	    {_,Port} = WorldTcpAddress#net_address.address,
	    ErlEpmd = net_kernel:epmd_module(),
	    case ErlEpmd:register_node(Name, Port, Driver) of
		{ok, Creation} ->
		    {reply, {ok, {Socket, TcpAddress, Creation}},
		     State#state{listen={Socket, World}}};
		{error, _} = Error ->
		    {reply, Error, State}
	    end;
	Error ->
	    {reply, Error, State}
    end;

handle_call({accept, _Driver, Listen}, {From, _}, State = #state{listen={_, World}}) ->
    Self = self(),
    ErtsPid = spawn_link(fun() -> accept_loop(Self, erts, Listen, From) end),
    WorldPid = spawn_link(fun() -> accept_loop(Self, world, World, Listen) end),
    {reply, ErtsPid, State#state{accept_loop={ErtsPid, WorldPid}}};

handle_call({connect, Driver, Ip, Port}, {From, _}, State) ->
    Me = self(),
    Pid = spawn_link(fun() -> setup_proxy(Driver, Ip, Port, Me) end),
    receive 
	{Pid, go_ahead, LPort} -> 
	    Res = {ok, Socket} = try_connect(LPort),
	    case gen_tcp:controlling_process(Socket, From) of
		{error, badarg} = Error -> {reply, Error, State};   % From is dead anyway.
		ok ->
		    flush_old_controller(From, Socket),
		    {reply, Res, State}
	    end;
	{Pid, Error} ->
	    {reply, Error, State}
    end;

handle_call(_What, _From, State) ->
    {reply, ok, State}.

handle_cast(_What, State) ->
    {noreply, State}.

handle_info(_What, State) ->
    {noreply, State}.

terminate(_Reason, _St) ->
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
get_tcp_address(Socket) ->
    case inet:sockname(Socket) of
	{ok, Address} ->
	    {ok, Host} = inet:gethostname(),
	    NetAddress = #net_address{
			    address = Address,
			    host = Host,
			    protocol = proxy,
			    family = inet
			   },
	    {ok, NetAddress};
	{error, _} = Error -> Error
    end.

accept_loop(Proxy, erts = Type, Listen, Extra) ->
    process_flag(priority, max),
    case gen_tcp:accept(Listen) of
	{ok, Socket} ->
	    Extra ! {accept,self(),Socket,inet,proxy},
	    receive 
		{_Kernel, controller, Pid} ->
		    inet:setopts(Socket, [nodelay()]),
		    ok = gen_tcp:controlling_process(Socket, Pid),
		    flush_old_controller(Pid, Socket),
		    Pid ! {self(), controller};
		{_Kernel, unsupported_protocol} ->
		    exit(unsupported_protocol)
	    end;
	{error, closed} ->
	    %% The listening socket is closed: the proxy process is
	    %% shutting down.  Exit normally, to avoid generating a
	    %% spurious error report.
	    exit(normal);
	Error ->
	    exit(Error)
    end,
    accept_loop(Proxy, Type, Listen, Extra);

accept_loop(Proxy, world = Type, Listen, Extra) ->
    process_flag(priority, max),
    case gen_tcp:accept(Listen) of
	{ok, Socket} ->
	    Opts = get_ssl_options(server),
	    wait_for_code_server(),
	    case ?ssl_accept(Socket, Opts) of
		{ok, SslSocket} ->
		    PairHandler = spawn_link(fun() -> setup_connection(SslSocket, Extra) end),
		    ok = ssl:controlling_process(SslSocket, PairHandler),
		    flush_old_controller(PairHandler, SslSocket);
		{error, {options, _}} = Error ->
		    %% Bad options: that's probably our fault.  Let's log that.
		    ?LOG_ERROR("Cannot accept TLS distribution connection: ~s~n",
					   [ssl:format_error(Error)]),
		    gen_tcp:close(Socket);
		_ ->
		    gen_tcp:close(Socket)
	    end;
	Error ->
	    exit(Error)
    end,
    accept_loop(Proxy, Type, Listen, Extra).

wait_for_code_server() ->
    %% This is an ugly hack.  Upgrading a socket to TLS requires the
    %% crypto module to be loaded.  Loading the crypto module triggers
    %% its on_load function, which calls code:priv_dir/1 to find the
    %% directory where its NIF library is.  However, distribution is
    %% started earlier than the code server, so the code server is not
    %% necessarily started yet, and code:priv_dir/1 might fail because
    %% of that, if we receive an incoming connection on the
    %% distribution port early enough.
    %%
    %% If the on_load function of a module fails, the module is
    %% unloaded, and the function call that triggered loading it fails
    %% with 'undef', which is rather confusing.
    %%
    %% Thus, the ssl_tls_dist_proxy process will terminate, and be
    %% restarted by ssl_dist_sup.  However, it won't have any memory
    %% of being asked by net_kernel to listen for incoming
    %% connections.  Hence, the node will believe that it's open for
    %% distribution, but it actually isn't.
    %%
    %% So let's avoid that by waiting for the code server to start.
    case whereis(code_server) of
	undefined ->
	    timer:sleep(10),
	    wait_for_code_server();
	Pid when is_pid(Pid) ->
	    ok
    end.

try_connect(Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [{active, false}, {buffer, 65536}, {packet,?PPRE}, nodelay(), {reuseaddr, true}]) of
	R = {ok, _S} ->
	    R;
	{error, _R} ->
	    try_connect(Port)
    end.

setup_proxy(Driver, Ip, Port, Parent) ->
    process_flag(trap_exit, true),
    Opts = connect_options(get_ssl_options(client)),
    SSLDefaultConnOpts = [{active, true}, binary, {packet,?PPRE}, nodelay(), {reuseaddr, true}, {buffer, 65536}, Driver:family()],
    case ssl:connect(Ip, Port, SSLDefaultConnOpts ++ Opts) of
	{ok, World} ->
	    {ok, ErtsL} = gen_tcp:listen(0, [{active, true}, {ip, loopback}, binary, {packet,?PPRE}, {buffer, 65536}]),
	    {ok, #net_address{address={_,LPort}}} = get_tcp_address(ErtsL),
	    Parent ! {self(), go_ahead, LPort},
	    case gen_tcp:accept(ErtsL) of
		{ok, Erts} ->
		    %% gen_tcp:close(ErtsL),
		    loop_conn_setup(World, Erts);
		Err ->
		    Parent ! {self(), Err}
	    end;
	{error, {options, _}} = Err ->
	    %% Bad options: that's probably our fault.  Let's log that.
	    ?LOG_ERROR("Cannot open TLS distribution connection: ~s~n",
				   [ssl:format_error(Err)]),
	    Parent ! {self(), Err};
	Err ->
	    Parent ! {self(), Err}
    end.


%% we may not always want the nodelay behaviour
%% %% for performance reasons

nodelay() ->
    case application:get_env(kernel, dist_nodelay) of
        {ok, true} -> {nodelay, true};
        _ -> {nodelay, false}
    end.

setup_connection(World, ErtsListen) ->
    process_flag(trap_exit, true),
    {ok, TcpAddress} = get_tcp_address(ErtsListen),
    {_Addr,Port} = TcpAddress#net_address.address,
    case gen_tcp:connect({127,0,0,1}, Port, [{active, true}, {buffer, 65536}, binary, {packet,?PPRE}, nodelay(), {reuseaddr, true}]) of
        {ok, Erts} ->
            ssl:setopts(World, [{active,true}, {packet,?PPRE}, nodelay()]),
            loop_conn_setup(World, Erts);
        Error ->
            ?LOG_ERROR("Failed to setup connection to erts with ~p", [Error]),
            ssl:close(World)
    end.


loop_conn_setup(World, Erts) ->
    receive 
        {ssl, World, Data = <<$a, _/binary>>} ->
            gen_tcp:send(Erts, Data),
            ssl:setopts(World, [{packet,?PPOST}, nodelay(), {active, once}]),
            inet:setopts(Erts, [{packet,?PPOST}, nodelay(), {active, once}]),
            loop_conn(World, Erts);
        {tcp, Erts, Data = <<$a, _/binary>>} ->
            ssl:send(World, Data),
            ssl:setopts(World, [{packet,?PPOST}, nodelay(), {active, once}]),
            inet:setopts(Erts, [{packet,?PPOST}, nodelay(), {active, once}]),
            loop_conn(World, Erts);
        {ssl, World, Data = <<_, _/binary>>} ->
            gen_tcp:send(Erts, Data),
            loop_conn_setup(World, Erts);
        {tcp, Erts, Data = <<_, _/binary>>} ->
            ssl:send(World, Data),
            loop_conn_setup(World, Erts);
        {ssl, World, Data} ->
            gen_tcp:send(Erts, Data),
            loop_conn_setup(World, Erts);
        {tcp, Erts, Data} ->
            ssl:send(World, Data),
            loop_conn_setup(World, Erts);
        {tcp_closed, Erts} ->
            ssl:close(World);
        {ssl_closed,  World} ->
            gen_tcp:close(Erts);
        {ssl_error, World, _} ->
            ssl:close(World)
    end.

loop_conn(World, Erts) ->
    receive
        {ssl, World, Data} ->
            gen_tcp:send(Erts, Data),
            ssl:setopts(World, [{active, once}]),
            loop_conn(World, Erts);
        {tcp, Erts, Data} ->
            ssl:send(World, Data),
            inet:setopts(Erts, [{active, once}]),
            loop_conn(World, Erts);
        {tcp_closed, Erts} ->
            ssl:close(World);
        {ssl_closed,  World} ->
            gen_tcp:close(Erts);
        {ssl_error, World, _} ->
            ssl:close(World)
    end.


get_ssl_options(Type) ->
    application:load(epmdless_dist),
    {ok, Config} = application:get_env(epmdless_dist, ssl_dist_opt),
    proplists:get_value(Type, Config).


flush_old_controller(Pid, Socket) ->
    receive
	{tcp, Socket, Data} ->
	    Pid ! {tcp, Socket, Data},
	    flush_old_controller(Pid, Socket);
	{tcp_closed, Socket} ->
	    Pid ! {tcp_closed, Socket},
	    flush_old_controller(Pid, Socket);
	{ssl, Socket, Data} ->
	    Pid ! {ssl, Socket, Data},
	    flush_old_controller(Pid, Socket);
	{ssl_closed, Socket} ->
	    Pid ! {ssl_closed, Socket},
	    flush_old_controller(Pid, Socket)
    after 0 ->
	    ok
    end.
