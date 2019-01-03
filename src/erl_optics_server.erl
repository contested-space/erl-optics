-module(erl_optics_server).

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start_link/1, poll/0, stop/0, send_metrics/0]).

-define(SERVER, ?MODULE).

-record(state, {port, lsock}).


%%%=========
%%% API
%%%=========

start_link(Port) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port], []).

poll() ->
    gen_server:call(?SERVER, poll).

send_metrics() ->
    gen_server:call(?SERVER, send_metrics).

stop() ->
    gen_server:cast(?SERVER, stop).


%%%==========
%%% Callbacks
%%%==========

init([Port]) ->
    %inets:start(),
    {ok, LSock} = gen_tcp:listen(Port, [{active, true}]),
    {ok, _Sock} = gen_tcp:accept(LSock),
    {ok, #state{port = Port, lsock = LSock}, 0}.

handle_call(poll, _From, State) ->
    {reply, erl_optics:poll(), State};

handle_call(send_metrics, _From, State) ->
        {reply, httpc:request("http://www.erlang.org"), State}.

handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info(timeout, State) ->
    {noreply, State};

handle_info({tcp, Socket, RawData}, State) ->
    io:format("info received\n"),
    io:format("Raw data: "),
    io:format(RawData),
    io:format("\n"),
    R = re:replace(RawData, "\r\n$", "", [{return, list}]),
    case R of
        "prometheus" ->
            io:format(prometheus_polling()),
            gen_tcp:send(Socket, "prometheus_polling called\n");
        _ ->
            gen_tcp:send(Socket, "something useful\n")
    end,
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================
%%% Internal functions
%%%===================

prometheus_polling() ->
    {Ok, Map} = erl_optics:poll(),
    maps:keys(Map).
