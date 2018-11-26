-module(erl_optics_utils).

-export([multiple_counter_lens/2, multiple_counter_lens/3]).



multiple_counter_lens_in(Key, Generator, 0, Lst)->
    Lst;

multiple_counter_lens_in(Key, Generator, N, Lst)->
    multiple_counter_lens_in(Key, Generator, N-1, [erl_optics_lens:counter(Generator(Key, N))|Lst]).

multiple_counter_lens(Key, N)->
    multiple_counter_lens_in(Key, fun(K, Nb) -> default_generator(K, Nb) end, N, []).
                                          
multiple_counter_lens(Key, Generator, N)->
    multiple_counter_lens_in(Key, Generator, N, []).
    
default_generator(Key, N)->
    list_to_binary([Key, $., integer_to_binary(N)]).


