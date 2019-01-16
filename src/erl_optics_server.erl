-module(erl_optics_server).
-include("erl_optics.hrl").

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start_link/2,
         stop/0]).

%for prototyping only
-export([start/0,
         poll_map_to_string/1,
         test_update/0,
         start_test/1]).

-define(SERVER, ?MODULE).

-record(state, {port = ?ENV_PORT     :: inet:port_number(),
                lsock                :: gen_tcp:socket(),
                addr = ?ENV_HOSTNAME :: inet:socket_address() | inet:hostname(),
                sock                 :: gen_tcp:socket(),
                poller_buffer = []   :: iolist(),
                is_connected = false :: boolean(),
                mode                 :: carbon | prometheus}).


%%%=========
%%% API
%%%=========

%Modes: prometheus | {carbon, interval=integer()}

start_link(Port, Mode) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port, Mode], []).

stop() ->
    gen_server:cast(?SERVER, stop).

start_test(Interval) ->
    gen_server:cast(?SERVER, {test_update, Interval}).

%%%==========
%%% Callbacks
%%%==========

init([Port, Mode]) ->
    case Mode of
        {carbon, Interval} ->
            gen_server:cast(?SERVER, connect),
            timer:send_interval(Interval, carbon_poll),
            gen_server:cast(?SERVER, {test_update, 10}), %for testing
            {ok, #state{mode = carbon}, 0};
        prometheus ->
            {ok, LSock} = gen_tcp:listen(Port, [{active, true}]),
            {ok, _Sock} = gen_tcp:accept(LSock),
            {ok, #state{port = Port, lsock = LSock}, 0}
    end.

handle_call(poll, _From, State) ->
    {reply, erl_optics:poll(), State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({test_update, Interval}, State) ->
    timer:send_interval(Interval, test_update),
    {noreply, State};
handle_cast(connect, State) ->
    io:format("In connect\n"),
    case connect(State) of
        {ok, Sock} ->
            {noreply,
            State#state {
                sock = Sock,
                is_connected = true}};
        {error, Reason} ->
            reconnect(State),
            {noreply, State}
    end.


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
            {ok, Map} = erl_optics:poll(),
            gen_tcp:send(Socket, poll_map_to_string(Map));
        _ ->
            gen_tcp:send(Socket, <<"something useful\n">>)
    end,
    {noreply, State};
handle_info(test_update, State) ->
    test_update(),
    {noreply, State};
handle_info(carbon_poll, State) ->
    {ok, Poll} = poll(),
    PollNow = poll_map_to_string(Poll),
    PollerBuf = State#state.poller_buffer,
    case State#state.is_connected of
        true ->
            io:format("Timed polling happens\n"),
            Socket = State#state.sock,
            PollOutput = list_to_binary([PollNow | PollerBuf]),
            io:format(PollOutput),
            gen_tcp:send(Socket, PollOutput),
            {noreply, State#state{poller_buffer = []}};
        false ->
            io:format("Disconnected\n"),

            case length(PollerBuf) < ?MAX_BUFFER_LENGTH of
                true ->
                    {noreply, State#state{poller_buffer = [PollNow | PollerBuf]}};
                false ->
                    NewPollerBuf = lists:droplast(PollerBuf),
                    {noreply, State#state{poller_buffer = [PollNow | NewPollerBuf]}}
            end
    end;
handle_info({tcp_closed, _Sock}, State) ->
    reconnect(State#state{is_connected = false}),
    {noreply, State#state{is_connected = false}};
handle_info(reconnect, State) ->
    io:format("In reconnect\n"),
    gen_server:cast(?SERVER, connect),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%%%===================
%%% Internal functions
%%%===================

%not really implemented for now, only outputs the keys
prometheus_polling() ->
    {ok, Map} = erl_optics:poll(),
    maps:keys(Map).

poll() ->
    {ok, Map} = erl_optics:poll(),
    {ok, {Map, os:timestamp()}}.


carbon_metric_format(Key, Val) ->
    {Prefix, Name} = Key,
    {Type, Value} = Val,
    {ok, Hostname} = inet:gethostname(),
    case Type of
        counter ->
            [list_to_binary([
                Prefix, $.,
                Hostname, $.,
                Name, <<" ">>,
                integer_to_binary(Value)])]; %10 is the endline
        gauge ->
            [list_to_binary([
                Prefix, $.,
                Hostname, $.,
                Name, <<" ">>,
                float_to_binary(Value)])]; %10 is the endline
        dist ->
            [list_to_binary([
                Prefix, $.,
                Hostname, $.,
                Name, $.,
                atom_to_binary(K, latin1), <<" ">>,
                case K of
                    n ->
                        integer_to_binary(V);
                    _ ->
                        float_to_binary(V)
                end]) || {K, V}  <- maps:to_list(Value)];
        histo ->
            [list_to_binary([
                Prefix, $.,
                Hostname, $.,
                Name, $.,
                case K of
                    below ->
                        atom_to_binary(K, latin1);
                    above ->
                        atom_to_binary(K, latin1);
                    {Min, Max} when is_integer(Min) and is_integer(Max) ->
                        list_to_binary([
                            <<"bucket_">>,
                            integer_to_binary(Min),
                            $_,
                            integer_to_binary(Max)]);
                    Error ->
                        Error
                end, <<" ">>,
                integer_to_binary(V)]) || {K, V}  <- maps:to_list(Value)];
        quantile ->
            [list_to_binary([
                Prefix, $.,
                Hostname, $.,
                Name, $.,
                atom_to_binary(K, latin1), <<" ">>,
                case K of
                    quantile ->
                        float_to_binary(V);
                    sample ->
                        float_to_binary(V);
                    sample_count ->
                        integer_to_binary(V);
                    count ->
                        integer_to_binary(V);
                    Err -> Err
                end]) ||  {K, V} <- maps:to_list(Value)];
        Other ->
            {error, {Other, "not a lens type"}}
    end.


poll_map_to_string(Poll) ->
    {Map, Stamp} = Poll,
    StrMap = maps:map(fun(K, V) ->
        carbon_metric_format(K, V)
        end, Map),
    StrList = lists:map(fun(Str) ->
        [
            Str, <<" ">>,
            integer_to_binary(timestamp_to_seconds(Stamp)),
            <<"\n">>]
        end,
        lists:flatten(maps:values(StrMap))),
    StrList.

timestamp_to_seconds(Stamp) ->
    {Mega, Sec, Micro} = Stamp,
    Mega * 1000000 + Sec.

start() ->
    Lenses = [
        erl_optics_lens:counter(<<"bob_the_counter">>),
        erl_optics_lens:dist(<<"bob_the_dist">>),
        erl_optics_lens:gauge(<<"bob_the_gauge">>),
        erl_optics_lens:histo(<<"bob_the_histo">>, [0, 10, 20, 30, 40]),
        erl_optics_lens:quantile(<<"bob_the_quantile">>, 0.5, 0.0, 0.01)
    ],
    erl_optics:start(<<"test">>, Lenses).

test_update() ->
    erl_optics:counter_inc(<<"bob_the_counter">>),
    %erl_optics:dist_record_timing_now_us(<<"bob_the_dist">>, os:timestamp()),
    %erl_optics:dist_record(<<"bob_the_dist">>, rand:normal()),
    erl_optics:dist_record(<<"bob_the_dist">>, 1.0),
    erl_optics:gauge_set(<<"bob_the_gauge">>, rand:uniform()),
    %erl_optics:quantile_update_timing_now_us(<<"bob_the_quantile">>, os:timestamp() ),
    erl_optics:quantile_update(<<"bob_the_quantile">>, rand:uniform()),
    erl_optics:histo_inc(<<"bob_the_histo">>, rand:uniform() * 40.0),
    ok.

connect(State) ->
    #state{addr = Addr, port = Port} = State,
    case gen_tcp:connect(Addr, Port, [binary, {active, true}]) of
        {ok, Socket} ->
            {ok, Socket};
        Error ->
            Error
    end.

reconnect(State) ->
    io:format("Sending reconnect\n"),
    erlang:send_after(1000, self(), reconnect).
