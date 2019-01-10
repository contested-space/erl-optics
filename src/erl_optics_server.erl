-module(erl_optics_server).

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start_link/2,
         stop/0,
         start_carbon/1]).

%for prototyping only
-export([start/0,
         poll/0,
         poll_map_to_string/1,
         test_update/0,
         start_test/1]).

-define(SERVER, ?MODULE).

-record(state, {port, lsock}).


%%%=========
%%% API
%%%=========

%Modes: request | {timer_poll, interval=integer()}

start_link(Port, Mode) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port, Mode], []).

send_metrics() ->
    gen_server:call(?SERVER, send_metrics).

stop() ->
    gen_server:cast(?SERVER, stop).

start_carbon(Interval) ->
    gen_server:cast(?SERVER, {start_carbon, Interval}).
%    timer:send_interval(Interval, timed_poll).

start_test(Interval) ->
    gen_server:cast(?SERVER, test_update).

%%%==========
%%% Callbacks
%%%==========

init([Port, Mode]) ->
    %Note: in the timer poll mode, change address so that it can be
    %      something other than local
    case Mode of
        {timer_poll, Interval} ->
            {ok, Hostname} = inet:gethostname(),
            {ok, Address} = inet:getaddr(Hostname, inet),
            {ok, Sock} = gen_tcp:connect(Address, Port, []),
            %timer:send_interval(Interval, carbon_poll),
            {ok, #state{port = Port, lsock = Sock}, 0};
        request ->
            {ok, LSock} = gen_tcp:listen(Port, [{active, true}]),
            {ok, _Sock} = gen_tcp:accept(LSock),
            {ok, #state{port = Port, lsock = LSock}, 0}
    end.


handle_call(poll, _From, State) ->
    {reply, erl_optics:poll(), State}.


handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({start_carbon, Interval}, State) ->
    timer:send_interval(Interval, carbon_poll),
    {noreply, State};
handle_cast(test_update, State) ->
    timer:send_interval(100, test_update),
    {noreply, State}.


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
    io:format("Timed polling happens\n"),
    {ok, Poll} = poll(),
    Socket = State#state.lsock,
    gen_tcp:send(Socket, poll_map_to_string(Poll)),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%%%===================
%%% Internal functions
%%%===================

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
            [list_to_binary([Prefix, $.,
                            Hostname, $.,
                            Name, 32, %32 is the space character
                            integer_to_binary(Value)])]; %10 is the endline
        gauge ->
            [list_to_binary([Prefix, $.,
                            Hostname, $.,
                            Name, 32, %32 is the space character
                            float_to_binary(Value)])]; %10 is the endline
        dist ->
            [list_to_binary([Prefix, $.,
                             Hostname, $.,
                             Name, $.,
                             atom_to_binary(K, latin1),
                             32,
                             case K of
                                 n ->
                                     integer_to_binary(V);
                                 _ ->
                                     float_to_binary(V)
                             end]) || {K, V}  <- maps:to_list(Value)];
        histo ->
            [list_to_binary([Prefix, $.,
                             Hostname, $.,
                             Name, $.,
                             case K of
                                 below ->
                                     atom_to_binary(K, latin1);
                                 above ->
                                     atom_to_binary(K, latin1);
                                 {Min, Max} when is_integer(Min) and is_integer(Max) ->
                                     list_to_binary([<<"bucket_">>,
                                                     integer_to_binary(Min),
                                                     $_,
                                                     integer_to_binary(Max)]);
                                 Error ->
                                     Error
                             end, 32,
                             integer_to_binary(V)]) || {K, V}  <- maps:to_list(Value)];

        quantile ->
            [list_to_binary([Prefix, $., Hostname, $., Name, $.,
                               atom_to_binary(K, latin1), 32,
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
    Str_map = maps:map(fun(K, V) ->
                               carbon_metric_format(K, V)
                       end, Map),
    Str_list = lists:map(fun(Str) ->
                                 list_to_binary([Str,
                                                 32,
                                                 integer_to_binary(timestamp_to_seconds(Stamp)),
                                                 10]) end,
                         lists:flatten(maps:values(Str_map))),
    list_to_binary(Str_list).

timestamp_to_seconds(Stamp) ->
    {Mega, Sec, Micro} = Stamp,
    Mega * 1000000 + Sec.

start() ->
    Lenses = [
        erl_optics_lens:counter(<<"bob_the_counter">>),
        erl_optics_lens:dist(<<"bob_the_dist">>),
        erl_optics_lens:gauge(<<"bob_the_gauge">>),
        erl_optics_lens:histo(<<"bob_the_histo">>, [0, 10, 20, 30, 40]),
        erl_optics_lens:quantile(<<"bob_the_quantile">>, 0.5, 0.5, 0.5)
    ],
    erl_optics:start(<<"test">>, Lenses).

test_update() ->
    erl_optics:counter_inc(<<"bob_the_counter">>),
    erl_optics:dist_record_timing_now_us(<<"bob_the_dist">>, os:timestamp()),
    erl_optics:gauge_set(<<"bob_the_gauge">>, random:uniform()),
    erl_optics:quantile_update_timing_now_us(<<"bob_the_quantile">>, os:timestamp() ),
    erl_optics:histo_inc(<<"bob_the_histo">>, random:uniform() * 40.0),
    ok.
