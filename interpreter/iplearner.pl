/* ***************************************************************************
 *                                            ####   ####           .-""-.    
 *       # #                             #   #    # #    #         /[] _ _\   
 *       # #                                 #    # #             _|_o_LII|_  
 * ,###, # #  ### ## ## ##   ###  ## ##  #   #    # #       ###  / | ==== | \ 
 * #   # # # #   # ## ## #  #   #  ## #  #   ###### #      #     |_| ==== |_| 
 * #   # # # ####  #  #  #  #   #  #  #  #   #    # #      ####   ||" ||  ||  
 * #   # # # #     #  #  #  #   #  #  #  #   #    # #    #    #   ||'----'||  
 * '###'# # # #### #  #  ##  ### # #  ## ## #      # ####  ###   /__|    |__\ 
 * ***************************************************************************
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; only version 2 of the License!
 * ***************************************************************************
 *
 *           $Id: iplearner.pl 183 2008-12-22 10:05:00Z dp $
 *         @date: 22.12.08
 *       @author: Dennis Pannhausen <Dennis.Pannhausen@rwth-aachen.de>
 *   description: (i)nductive (p)olicy (l)earning
 *
 * **************************************************************************/

% ================================================================== %
%  INDUCTIVE POLICY LEARNER                                          %
% ================================================================== %

%  If the corresponding flag is true, the IPLearner is invoked
%  whenever a solve statement is interpreted by Readylog.
%  The task of inductive policy learning is to learn a decision
%  tree from seeing different situations (described by all fluent
%  values) and corresponding decisions (here: decision-theoretic
%  policies).
%  When the the decision tree for a certain solve statement is
%  sufficiently good, the IPLearner replaces the solve statement
%  by the tree in the Readylog code. Readylog then supplies the
%  tree with the current fluent values and the tree returns a
%  policy (approximating a decision theoretically planned one).


:- write("** loading iplearner.pl\n"). 

% --------------------------------------------------------- %
%  Header + Flags                                           %
% --------------------------------------------------------- %
% {{{ header + flags

:- ensure_loaded('iplutils.pl').

%  needed by "get_all_fluent_names"
:- lib(ordset).

% }}}


% ---------------------------------------------------------- %
%  Initialisation                                            %
% ---------------------------------------------------------- %

initialise_iplearner :-
%        get_flag(cwd, CWD),
%        printf( stdout, "******* CURRENT WORKING DIR: %w\n", [CWD]),
%        flush(stdout),
        %  Constant telling if there are parameterised exogenous
        %  primitive fluents (compounds containing vars) in the world model.
        get_all_fluent_names(FluentNames),
        contains_param_exog_prim_fluent(FluentNames, Result),
        setval(param_exog_prim_fluents, Result),
        printf(stdout, "setval(param_exog_prim_fluents, %w)\n", [Result]),
        %  Constant giving a maximum threshold for the hypothesis error [0,1].
        %  If the error of the decision tree of a solve context it below that
        %  error, we switch to the consultation phase for that solve.
        setval(max_hypothesis_error, 0.2),
        %  Create a hash table to store the filenames (keys) for
        %  the different solve contexts (values).
        hash_create(SolveHashTable), setval(solve_hash_table, SolveHashTable),
        %  If not already stored on disk, create a fresh hash table to store the keys
        %  for the different policies (values).
        ( not(exists('policies.hash')) ->
           printf("policies.hash doesn't exists -> create fresh hash tables\n", []),
           flush(stdout),
           hash_create(PolicyHashTable), setval(policy_hash_table, PolicyHashTable),
           %  Create hash tables to store the (average) Value, (average) TermProb,
           %  and (debugging) Tree for a policy with the corresponding hash key.
           hash_create(PolicyValueHashTable),
           hash_create(PolicyTermprobHashTable),
           hash_create(PolicyTreeHashTable)
        ;
           printf("policies.hash exists -> create hash tables from file\n", []),
           flush(stdout),
           %  Otherwise construct hash lists from the file.
           create_hash_lists_from_files( PolicyHashTable,
                                         PolicyValueHashTable,
                                         PolicyTermprobHashTable,
                                         PolicyTreeHashTable )
        ),
        setval(policy_hash_table, PolicyHashTable),
        setval(policy_value_hash_table, PolicyValueHashTable),
        setval(policy_termprob_hash_table, PolicyTermprobHashTable),
        setval(policy_tree_hash_table, PolicyTreeHashTable),
        %  Global list that stores the fluent list that we use for training
        %  the C4.5 decision tree.
        ( not(exists('ipl.fluents')) ->
           printf("ipl.fluents doesn't exists -> setting ipl_fluents = []\n",
                  []),
           flush(stdout),
           setval( ipl_fluents, [] ),
           %  Is IPL still in pre-training phase (collecting calls for
           %  parameterised exogenous fluents).
           setval(ipl_pre_training_phase, true)
        ;
           printf("ipl.fluents exists -> initialising ipl_fluents from file\n",
                   []),
           printf("setting ipl_pre_training_phase = false\n", []),
           flush(stdout),
           initialise_ipl_fluents,
           %  Is IPL still in pre-training phase (collecting calls for
           %  parameterised exogenous fluents).
           setval(ipl_pre_training_phase, false)
        ),
        %  Constant defining the maximum domain size for a pickBest.
        setval( pick_best_domain_size_max, 10 ),
        %  Global list that stores has_val calls to parameterised exogenous
        %  primitive fluents (compounds containing vars), whenever IPLearning
        %  is active.
        setval( param_exog_prim_fluent_calls, [] ),
        %  System time of the last change
        %  to the list param_exog_prim_fluent_calls. 
        setval( last_change_to_fluent_calls, _Uninstantiated ),
        %  Set the (heuristic) time difference, that we use to decide
        %  when to start with the IPL training phase.
        %  If the time of the last change to the list
        %  param_exog_prim_fluent_calls has been over for
        %  param_exog_prim_fluent_delta, then determine_ipl_phase/1
        %  triggers the training phase.
        setval( param_exog_prim_fluent_delta, 0.5 ).
        
%  Shortcuts.
param_exog_prim_fluents :- getval(param_exog_prim_fluents, X), X=true.

ipl_pre_training_phase :- getval(ipl_pre_training_phase, X), X=true.



% ---------------------------------------------------------- %
%  Utilities                                                 %
% ---------------------------------------------------------- %

%  Reads in the list of fluents that are relevant for IPL
%  from the file "ipl.fluents" and initialises the
%  global list ipl_fluents.
initialise_ipl_fluents :-
        printf(stdout, "Reading in ipl.fluents ... ", []),
        flush(stdout),
        open('ipl.fluents', read, Stream1),
        read_string(Stream1, end_of_line, _, _),
        read_string(Stream1, end_of_file, _, ByteList),
        printf(stdout, "successfully.\n", []),
        close(Stream1),
        bytes_to_term(ByteList, Fluents),
%        printf(stdout, "ipl.Fluents: %w\n", [Fluents]),
        setval(ipl_fluents, Fluents).

%        string_length(FS, FSLength),
%        ReducedLength is (FSLength - 2),
%        substring(FS, 2, ReducedLength, FSNoBrackets),
%        split_string( FSNoBrackets, ",", " \t", FStringList),
%        findall( X,
%                 ( member(XS, FStringList),
%                   term_string(X, XS)
%                 ),
%                 Fluents),
%        printf(stdout, "ipl.Fluents: %w\n", [Fluents]),
%        setval(ipl_fluents, Fluents).

%  Returns an ordered set Result of all fluent names as Prolog terms.
:- mode get_all_fluent_names(-).
get_all_fluent_names(Result) :-
        %  Get all fluents.
        findall(PrimF, prim_fluent(PrimF), PrimFList),
        findall(ContF, cont_fluent(ContF), ContFList),
        findall(ExogPrimF, exog_prim_fluent(ExogPrimF), ExogPrimFList),
        findall(ExogCrimF, exog_cont_fluent(ExogCrimF), ExogContFList),
        %  Get all registers (which are fluents, too).
        findall(Reg, register(Reg), RegL),
        %  Define all built-in fluents.
        BuiltInTemp=[online, start, pll(_, _, _, _), pproj(_, _), 
                     lookahead(_, _, _, _), bel(_), ltp(_)],
%        ignore_fluents(IFL), 
%        append(BuiltInTemp, IFL, BuiltIn),
        %  The list of all defined fluents.
        FluentLTmp=[PrimFList, ContFList, ExogPrimFList, ExogContFList],
        flatten(FluentLTmp, FluentL),
%        BuiltInTmp = [BuiltIn, RegL], flatten(BuiltInTmp, BuiltInL),
        BuiltInTmp = [BuiltInTemp, RegL],
        flatten(BuiltInTmp, BuiltInL),
        subtract(FluentL, BuiltInL, ResultList),
        list_to_ord_set(ResultList, Result).


%  Returns an ordered set Result of all fluents that are
%  evaluable and have been projected to one dimension.
%  The list contains the fluent names in byte form!
:- mode ipl_get_all_fluent_names(-).
ipl_get_all_fluent_names(S, Result) :-
        param_exog_prim_fluents,
        ipl_pre_training_phase,
        !,
        %  ipl_fluents still is the empty list.
        %  Get all fluents.
        get_all_fluent_names( AllFluents ),
        %  Remove all exog_prim_fluents with parameters that are
        %  not instantiated or that are not evaluable (not valid)
        findall( NonGroundParamF,
                 ( member(NonGroundParamF, AllFluents),
                   is_param_exog_prim_fluent(NonGroundParamF),
                   not(ground(NonGroundParamF))
                 ),
                 NonGroundParamFluents ),
        subtract( AllFluents, NonGroundParamFluents, GroundFluents ),
        %  Add all parameterised from the list
        %  param_exog_prim_fluent_calls. Those are all ground.
        getval( param_exog_prim_fluent_calls, CalledFluents ),
        ResultTmp1 = [GroundFluents, CalledFluents],
        flatten( ResultTmp1, ResultTmp1Flat ),
        findall( Fluents1D,
                 ( member(EvaluableFT, ResultTmp1Flat),
                   %  Transform fluent names to byte form.
                   term_to_bytes(EvaluableFT, EvaluableFB),
                   %  Only pick fluents that can be evaluated in
                   %  situation S.
                   is_valid_fluent(EvaluableFB, S),
                   %  Substitute n scalar fluents for
                   %  n-dimensional vectors.
                   project_from_n_to_1(EvaluableFB, S, Fluents1D)
                 ),
                 ResultTmp2 ),
        flatten( ResultTmp2, ResultFlat ),
        list_to_ord_set( ResultFlat, Result ).

ipl_get_all_fluent_names(_S, Result) :-
        param_exog_prim_fluents,
        !,
        %  ipl_fluents is set already.
        getval( ipl_fluents, Result ).

ipl_get_all_fluent_names(S, Result) :-
        %  We know: not(param_exog_prim_fluents)
        %  Get all fluents.
        get_all_fluent_names( ResultTmp1Flat ),
        findall( Fluents1D,
                 ( member(EvaluableFT, ResultTmp1Flat),
                   %  Transform fluent names to byte form.
                   term_to_bytes(EvaluableFT, EvaluableFB),
                   %  Only pick fluents that can be evaluated in
                   %  situation S.
                   is_valid_fluent(EvaluableFB, S),
                   %  Substitute n scalar fluents for
                   %  n-dimensional vectors.
                   project_from_n_to_1(EvaluableFB, S, Fluents1D)
                 ),
                 ResultTmp2 ),
        flatten( ResultTmp2, ResultFlat ),
        list_to_ord_set( ResultFlat, Result ).


%  Returns an ordered set Result of all fluent values.
%  Gets the current situation S as input.
:- mode get_all_fluent_values(++, -).
get_all_fluent_values(S, Result) :-
        printf(stdout, "Querying all fluent values...\n", []),
        cputime(TQueryBegin),
        ipl_get_all_fluent_names(S, Fluents),
        findall( ValFStringNoComma,
                 ( member(F, Fluents),
                   %  Check if fluent is instantiated and we can
                   %  evaluate it,
                   %  or if it is a projection of an n-dimensional
                   %  fluent; then we can evaluate it with
                   %  get_value_from_n_dim_fluent/4.
                   ( is_valid_fluent(F, S) ->
                      %  Check if the fluent is a projection of an
                      %  n-dimensional fluent
                      ( is_projected_fluent(F) ->
                          get_value_from_n_dim_fluent(F, S, ValF)
                      ;
                          bytes_to_term(F, FT),
                          %  Fluent is instantiated and 1-dimensional.
                          ( exog_fluent(FT) ->
%                             printf(stdout, "Fluent %w is an exogenous fluent...\n", [FT]),
                             exog_fluent_getValue(FT, ValF, S)%,
%                             printf(stdout, "and has value %w.\n", [ValF])
                          ;
%                             printf(stdout, "Fluent %w is *NOT* an exogenous fluent...\n", [FT]),
                             subf(FT, ValF, S)%,
%                             printf(stdout, "and has value %w.\n", [ValF])
                          )
                      )
                   ;
                      printf(stdout, "*** Warning: *** ", []),
                      printf(stdout, "Fluent %w is not valid. ", [F]),
                      printf(stdout, "Fluent is ignored.\n", []),
                      false
                   ),
                   %  Replace commas, as C4.5 forbids them in
                   %  attribute values.
                   %  Note, that, in general, ValF is a list!
                   term_string(ValF, ValFString),
                   replace_string(ValFString, ",", "COMMA",
                                  ValFStringTmp),
                   %  Replace ", as they are part of the fluent value
                   %  and otherwise would be interpreted as string
                   %  identifier by Prolog during later conversion.
                   replace_string(ValFStringTmp, "\"", "QUOTATION",
                                  ValFStringNoComma)
                 ),
                 Result ),
%        print_list(Result),
        cputime(TQueryEnd),
        TQueryDiff is TQueryEnd - TQueryBegin,
        printf(stdout, "with success in %w sec.\n", [TQueryDiff]).
                   

%  Tests if fluent F (in byte form!) is instantiated and we can evaluate
%  it in situation S.
:- mode is_valid_fluent(++, ++).
is_valid_fluent(F, S) :-
        %  Fluents that have been projected to one dimension
        %  are valid.
        is_projected_fluent(F),
        !,
        get_value_from_n_dim_fluent(F, S, _ValF).

is_valid_fluent(F, S) :-
        nonvar(F),
        bytes_to_term(F, FT),
        exog_fluent(FT),
        !,
        exog_fluent_getValue(FT, _ValF, S).

is_valid_fluent(F, S) :-
        nonvar(F),
        bytes_to_term(F, FT),
        exog_fluent(FT),
        subf(FT, _ValF, S).
        

%  Checks if a fluent (in byte form!) has been projected to a scalar from
%  an n-dimensional fluent.
:- mode is_projected_fluent(++).
is_projected_fluent(F) :-
         bytes_to_term(F, ProjectedFluent),
         ProjectedFluent = projected_fluent(_I, _N, _FluentND).


%  Decides, if fluent F (in byte form!) is continuous,
%  based on its value in situation S.
:- mode is_continuous(++, ++).
is_continuous( F, S ) :-
        is_projected_fluent(F),
        !,
        %  Fluent has been projected to one dimension.
        get_value_from_n_dim_fluent(F, S, ValF),
        float(ValF).

is_continuous( F, S ) :-
        nonvar(F),
        bytes_to_term(F, FT),
        exog_fluent(FT), !,
        exog_fluent_getValue(FT, ValF, S),
        float(ValF).

is_continuous( F, S ) :-
        nonvar(F),
        bytes_to_term(F, FT),
        subf(FT, ValF, S),
        float(ValF).
        

%  Sets the global list of fluent names for IPLearning in situation S.
:- mode set_ipl_fluent_names(++).
set_ipl_fluent_names(S) :-
        ipl_get_all_fluent_names( S, List ),
        setval( ipl_fluents, List ),
        %  Write ipl_fluents to file.
        %  First convert the list to byte form. This is not human-readable,
        %  but allows us to get valid terms from the string, even if
        %  the string contains quotation marks or is a callable like
        %  epf_fluent("Param1", param2).
        term_to_bytes(List, ByteList),
        open("ipl.fluents", write, Stream),
        printf(Stream, "### IPL fluents: ###\n", []),
        printf(Stream, "%w\n", [ByteList]),
        close(Stream).
                  

%  Returns the dimension N of a fluent F (in byte form) in situation S.
:- mode fluent_dimension(++, ++, -).
fluent_dimension(F, S, N) :-
        ( is_valid_fluent(F, S) ->
           bytes_to_term(F, FT),
           ( exog_fluent(FT) ->
              exog_fluent_getValue(FT, ValF, S)
           ;
              subf(FT, ValF, S)
           ),
           fluent_dimension_aux(ValF, N)%,
%           printf(stdout, "Dimension of Fluent %w is %w, its Val is: %w.\n",
%                 [FT, N, ValF]), flush(stdout)
        ;
           printf(stdout, "Fluent: %w is not a valid fluent.\n", [F]),
           flush(stdout),
           N = 1
        ).

%  Helper predicate for fluent_dimension/3.
%  Returns the dimension N of a fluent value ValF in situation S.
:- mode fluent_dimension_aux(++, -).
fluent_dimension_aux(ValF, N) :-
        not(is_list(ValF)),
        !,
        N = 1.

fluent_dimension_aux(ValF, N) :-
        length(ValF, N).
                      

%  Returns a list of n scalar fluents Fluents1D (in byte form!),
%  given a n-dimensional fluent FluentND (in byte form!) and a situation S.
:- mode project_from_n_to_1(++, ++, -).
project_from_n_to_1(FluentND, S, Fluents1D) :-
        fluent_dimension(FluentND, S, N),
        project_from_n_to_1_aux(FluentND, N, Fluents1D).

%  Helper predicate for project_from_n_to_1/3
%  Returns a list of n scalar fluent names Fluents1D,
%  given a N-dimensional fluent FluentND.
:- mode project_from_n_to_1_aux(++, ++, -).
project_from_n_to_1_aux(FluentND, 1, Fluents1D) :- !,
        %  Also convert 1D fluents to byte form.
        Fluents1D = FluentND.

project_from_n_to_1_aux(FluentND, N, Fluents1D) :-
        ( count(I, 1, N),
          foreach( Fluent1D, Fluents1D ),
          param(FluentND, N)
          do
%            term_string(I, IS),
%            term_string(N, NS),
            %  Convert the fluent name of the n-dimensional fluent
            %  to bytes, in order to be able to recover it later.
%            term_string(FluentND, FluentNDS),
%%            term_to_bytes(FluentND, FluentNDS),
%            replace_character(FluentNDSRaw, "\"", "\\\"", FluentNDS),
%            replace_character(FluentNDSRaw, "\"", "qUOTE", FluentNDS),
%%            concat_string(["dim_", IS, "_of_", NS, "_", FluentNDS],
%%                           Fluent1D)
            Fluent1DTmp = projected_fluent(I, N, FluentND),
            term_to_bytes(Fluent1DTmp, Fluent1D)
        ).


%  Evaluates a 1D fluent F (in byte form!) that it the result of the
%  projection from a n-dimensional fluent.
:- mode get_value_from_n_dim_fluent(++, ++, -).
get_value_from_n_dim_fluent(F, S, ValF) :-
        bytes_to_term(F, FT),
        FT = projected_fluent(I, _N, FluentND),
        %  Decipher name stem of n-dimensional fluent.
        bytes_to_term(FluentND, FluentNDT),
        get_value_from_n_dim_fluent(FluentNDT, I, S, ValF).


%        term_string(F, FString),
%        printf(stdout, "FString: %w.\n", [FString]),
%        string_length(FString, FStringLength),
%        substring(FString, OfPos, 4, "_of_"),
%        OfPosRight is (OfPos + 4),
%        CurrentDimLength is (OfPos - 6),
%        substring(FString, 6, CurrentDimLength, CurrentDimS),
%        printf(stdout, "CurrentDimS: %w.\n", [CurrentDimS]),
%
%        RestLength is (FStringLength - OfPosRight + 1),
%        substring(FString, OfPosRight, RestLength, RestString),
%        substring(RestString, BeforeStemPos, 1, "_"), !,  % Only match the
%                                                          % finding of the
%                                                          % pattern.
%        StemBegin is (BeforeStemPos + 1),
%        StemLength is (RestLength - StemBegin),
%        substring(RestString, StemBegin, StemLength, FluentStemString),
%        printf(stdout, "FluentStemString: %w.\n", [FluentStemString]),
%        term_string(FluentStemStringString, FluentStemString),
%        printf(stdout, "FluentStemStringString: %w.\n", [FluentStemStringString]),
%        bytes_to_term(FluentStemStringString, FluentStem),
%        printf(stdout, "FluentStem: %w.\n", [FluentStem]),
%        term_string(CurrentDim, CurrentDimS),
%        get_value_from_n_dim_fluent(FluentStem, CurrentDim, S, ValF).


%  Queries the CurrentDim's dimension of the TotalDim-dimensional
%  fluent FluentStem and returns the value of this entry.
:- mode get_value_from_n_dim_fluent(++, ++, ++, -).
get_value_from_n_dim_fluent(FluentStem, CurrentDim, S, ValF) :-
        ( exog_fluent(FluentStem) ->
           exog_fluent_getValue(FluentStem, ValFND, S)
        ;
           subf(FluentStem, ValFND, S)
        ),
        get_element(CurrentDim, ValFND, ValF).
           

%  Returns the I'th element from a List.        
:- mode get_element(++, ++, -).
get_element(1, List, Element) :- !,
        List = [Element | _Tail].

get_element(I, List, Element) :-
        List = [_Head | Tail],
        J is I - 1,
        get_element(J, Tail, Element).


%  Decide, whether we are in the pre-training phase, where we still collect
%  param_exog_prim_fluent calls, or we are in the training phase, where we
%  still collect training data and train the decision tree for the given
%  solve-context, or we are in the consultation phase for this solve-context.
:- mode determine_ipl_phase(++, ++, -).
%determine_ipl_phase( _Solve, _S, Phase ) :-
%        !,
%        Phase = "consult".

determine_ipl_phase( _Solve, _S, Phase ) :-
        param_exog_prim_fluents,
        ipl_pre_training_phase,
        getval( last_change_to_fluent_calls, TLastChange ),
        var( TLastChange ),
        !,
        Phase = "pre_train".

determine_ipl_phase( _Solve, _S, Phase ) :-
        param_exog_prim_fluents,
        ipl_pre_training_phase,
        getval( last_change_to_fluent_calls, TLastChange ),
        %  Since above clause failed, we know: nonvar( TLastChange )
        cputime(TNow),
        TDiff is (TNow - TLastChange),
        getval( param_exog_prim_fluent_delta, CollectionDelta ),
        (TDiff < CollectionDelta),
        !,
        printf(stdout, "Still collecting calls for parameterised ", []),
        printf(stdout, "primitive exogenous fluents. Solve is handled ", []),
        printf(stdout, "via DT-planning.\n", []),
        printf(stdout, "TLastChange: %w, TNow: %w, TDiff: %w\n", [TLastChange, TNow, TDiff]), flush(stdout),
        Phase = "pre_train".

determine_ipl_phase( _Solve, S, Phase ) :-
        param_exog_prim_fluents,
        ipl_pre_training_phase,
        %  Since above clause failed, we know: (TDiff >= CollectionDelta)
        !,
        getval( param_exog_prim_fluent_calls, FluentCalls ),
        length( FluentCalls, Calls ),
        printf(stdout, "Triggering IPL Training Phase!\n", []),
        printf(stdout, "We have collected %w calls for ", [Calls]),
        printf(stdout, "parameterised exogenous fluents.\n", []),
        printf(stdout, "Creating the list of fluents for IPLearning... ", []),
        set_ipl_fluent_names(S),
        printf(stdout, "done.\n", []),
        flush(stdout),
        setval( ipl_pre_training_phase, false ),
        Phase = "train".

determine_ipl_phase( HashKey, _S, Phase ) :-
        getval(solve_hash_table, SolveHashTable),
        not(hash_contains(SolveHashTable, HashKey)),
        !,
        %  solve context encountered for the first time.
        Phase = "train".

determine_ipl_phase( _HashKey, _S, Phase ) :-
%%        %  solve context has been encountered before.
%%        hypothesis_error(HashKey, Error),
%%        getval( max_hypothesis_error, MaxError ),
%%        ( Error > MaxError ),
        !,
        Phase = "train".

determine_ipl_phase( _HashKey, _S, Phase ) :-
        %  Since above clause failed, we know: ( Error =< MaxError )
        Phase = "consult".


%  Creates a hash key for the solve context/the policies and their filenames.
:- mode create_hash_key(++, -).
create_hash_key( Term, HashKey ) :-
        Term =.. [solve | _Args],
        !,
        term_hash( Term, -1, 1000, HashKey),
        printf(stdout, "solve has hash key %w.\n", [HashKey]).

create_hash_key( Term, HashKey ) :-
        term_hash( Term, -1, 1000, HashKey),
        printf(stdout, "Policy has hash key %w.\n", [HashKey]).


%  The predicate is true iff the given Stream gets ready for I/O in time 100.
:- mode stream_ready(++).
stream_ready( Stream ) :-
%        not at_eof( Stream ), % does not work as intended with the pipe stream
        select([Stream], 100, ReadyStream),
        ReadyStream \= [].

%  Skips through the (output)-stream Stream until Pattern is found or
%  Stream is "quiet for a while".
%  Prints skipped lines to stdout.
%  Returns String of the line where pattern is found.
%  Helper predicate for chatting with C4.5.
:- mode print_skip(++, ++, -).
print_skip( Stream, _Pattern, String ) :-
        not stream_ready( out ), !,
        printf("[print_skip] ***Error*** Stream '%w' is not ready for I/O ",
               [Stream]),
        printf("while trying to skip!\n", []),
        flush(stdout),
        String = "".

print_skip( Stream, _Pattern, String ) :-
        at_eof( Stream ), !,
        printf("[print_skip] ***Error*** Got empty Stream '%w' ", [Stream]),
        printf("while trying to skip!\n", []),
        flush(stdout),
        String = "".

print_skip( Stream, Pattern, String ) :-
        stream_ready( out ),
        read_string(Stream, end_of_line, _, String),
        ( substring(String, Pattern, _) ->
           true
        ;
           print_skip( Stream, Pattern, String )
        ).

%  Skips through the (output)-stream Stream until Pattern is found or
%  Stream is "quiet for a while".
%  Does not print skipped lines to stdout.
%  Returns String of the line where pattern is found.
%  Helper predicate for chatting with C4.5.
:- mode quiet_skip(++, ++, -).
/*quiet_skip( Stream, _Pattern, String ) :-
        not stream_ready( out ), !,
        printf("[quiet_skip] ***Error*** Stream '%w' is not ready for I/O ",
               [Stream]),
        printf("while trying to skip!\n", []),
        flush(stdout),
        String = "".

quiet_skip( Stream, _Pattern, String ) :-
        at_eof( Stream ), !,
        printf("[quiet_skip] ***Error*** Got empty Stream '%w' ", [Stream]),
        printf("while trying to skip!\n", []),
        flush(stdout),
        String = "".
*/
quiet_skip( Stream, Pattern, String ) :-
        stream_ready( out ),
        read_string(Stream, end_of_line, _, String),
        ( substring(String, Pattern, _) ->
           true
        ;
           quiet_skip( Stream, Pattern, String )
        ).

% --------------------------------------------------------- %
%  Learning Instances                                       %
% --------------------------------------------------------- %
% {{{ Learning Instances

%  The C4.5 .names file defines the values for the decision
%  outcomes, and the domains of the attribute values. The domain
%  can be "continuous", "discrete", or a comma-separated list of
%  discrete values (which is preferable to "discrete").
%  As we do not require the Readylog programmer to declare the
%  domain of the fluents, we simply define the domain of
%  discrete fluents as a discrete domain with 1000 entries maximum.

%  Writes the learning example to the C4.5 .names and .data files.
%  Gets the solve context (Prog, Horizon, RewardFunction),
%  the Policy that was computed by decision-theoretic planning,
%  the Value and TermProb of this DT policy,
%  the PolicyTree of this DT policy (for DT-debugging),
%  and the current situation S.
:- mode write_learning_instance(++, ++, ++, ++, ++, ++).
write_learning_instance( solve(Prog, Horizon, RewardFunction), Policy,
                         Value, TermProb, PolicyTree, S ) :-
        %  Create a hash key for the solve context and its filenames.
        getval(solve_hash_table, SolveHashTable),
        term_hash(solve(Prog, Horizon, RewardFunction), -1, 1000, HashKey),
        printf(stdout, "solve has hash key %w.\n", [HashKey]),
        term_string(HashKey, HashKeyString),
        %  Create a hash key for the policy.
        getval(policy_hash_table, PolicyHashTable),
        %  Construct a Hash Key for the context "[Solve, Policy]".
        %  The same Policy might appear in different solve contexts,
        %  and might have very different values in different solves.
        %  So we will keep apart policies from different solve contexts.
        term_hash([solve(Prog, Horizon, RewardFunction), Policy], -1, 1000,
                  PolicyHashKey),
        printf(stdout, "Policy has hash key %w.\n", [PolicyHashKey]),
        term_string(PolicyHashKey, PolicyHashKeyString),
        ( not(hash_contains(PolicyHashTable, PolicyHashKey)) ->
           %  Policy encountered for the first time.
           hash_set(PolicyHashTable, PolicyHashKey, Policy),
           setval(policy_hash_table, PolicyHashTable),
           %  Store the hash table on hard disk for later retrieval.
%           printf(stdout, "store_hash_list().\n", []),
           store_hash_list(PolicyHashTable, 'policies.hash')%,
%           printf(stdout, "succeeded in store_hash_list().\n", [])
        ;
           true
        ),
        %  Add the (average) Value, (average) TermProb, and Tree for this
        %  policy to the corresponding hash tables.
        getval(policy_value_hash_table, PolicyValueHashTable),
        ( hash_contains(PolicyValueHashTable, PolicyHashKey) ->
           %  There is already an average value for this policy (for this
           %  solve context).
           hash_get(PolicyValueHashTable, PolicyHashKey, OldAvgValue),
           NewAvgValue is ((OldAvgValue + Value) / 2),
           hash_set(PolicyValueHashTable, PolicyHashKey, NewAvgValue),
           store_hash_list(PolicyValueHashTable, 'values.hash')
        ;
           %  This is the first time that this policy is seen.
           hash_set(PolicyValueHashTable, PolicyHashKey, Value),
           setval(policy_value_hash_table, PolicyValueHashTable),
           store_hash_list(PolicyValueHashTable, 'values.hash')
        ),
        getval(policy_termprob_hash_table, PolicyTermprobHashTable),
        ( hash_contains(PolicyTermprobHashTable, PolicyHashKey) ->
           %  There is already an average termprob for this policy (for this
           %  solve context).
           hash_get(PolicyTermprobHashTable, PolicyHashKey, OldAvgTermprob),
           NewAvgTermprob is ((OldAvgTermprob + TermProb) / 2),
           hash_set(PolicyTermprobHashTable, PolicyHashKey, NewAvgTermprob),
           setval(policy_termprob_hash_table, PolicyTermprobHashTable),
           store_hash_list(PolicyTermprobHashTable, 'termprobs.hash')
        ;
           %  This is the first time that this policy is seen.
           hash_set(PolicyTermprobHashTable, PolicyHashKey, TermProb),
           setval(policy_termprob_hash_table, PolicyTermprobHashTable),
           store_hash_list(PolicyTermprobHashTable, 'termprobs.hash')
        ),
        getval(policy_tree_hash_table, PolicyTreeHashTable),
        ( hash_contains(PolicyTreeHashTable, PolicyHashKey) ->
           %  There is already a tree for this policy.
           true
        ;
           %  This is the first time that this policy is seen.
           hash_set(PolicyTreeHashTable, PolicyHashKey, PolicyTree),
           setval(policy_tree_hash_table, PolicyTreeHashTable),
           store_hash_list(PolicyTreeHashTable, 'trees.hash')
        ),
        ( not(hash_contains(SolveHashTable, HashKey)) ->
                %  solve context encountered for the first time.
                printf(stdout, "First encounter of this solve context.\n", []),
                hash_set(SolveHashTable, HashKey,
                        solve(Prog, Horizon, RewardFunction)),
                %  update "global" variable
                setval(solve_hash_table, SolveHashTable),

                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                %  Construct a                       %
                %  ####### C4.5 .names file #######  %
                %  for this solve context.           %
                %  Instantiates ContextString,       %
                %  FluentNames, and DecisionString   %
                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                construct_names_file( solve(Prog, Horizon,
                                      RewardFunction),
                                      PolicyHashKeyString, HashKeyString, S,
                                      ContextString, FluentNames,
                                      DecisionString ),

                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                %  Construct a                       %
                %  ##### C4.5 .data file #######     %
                %  for this solve context.           %
                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                construct_data_file( S, HashKeyString, ContextString,
                                     FluentNames, DecisionString )
        ;
                /** solve context has been encountered before. */
                printf(stdout, "This solve context has been encountered ", []),
                printf(stdout, "before.\n", []),

                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                %  Continue with                     %
                %  ##### C4.5 .names file #######    %
                %  Instantiates DecisionString.      %
                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                continue_names_file( PolicyHashKeyString, HashKeyString,
                                     DecisionString ),

                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                %  Continue with                     %
                %  ##### C4.5 .data file #######     %
                % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% %
                continue_data_file( S, HashKeyString, DecisionString )
        ).

%  Creates the C4.5 .names file for the solve context with key HashKeyString.
%  Returns the ContextString, FluentNames, and DecisionString which are
%  needed by construct_data_file/5.
%  Helper predicate for write_learning_instance/6.
:- mode construct_names_file(++, ++, ++, ++, -, -, -).
construct_names_file( solve(Prog, Horizon, RewardFunction), PolicyHashKeyString,
                      HashKeyString, S,
                      ContextString, FluentNames, DecisionString ) :-
        concat_string(["solve_context_", HashKeyString, ".names"], FileName),
        open(FileName, write, NameStream),
        printf(NameStream, "| ********************************\n", []),
        printf(NameStream, "| * file generated from ReadyLog *\n", []),
        printf(NameStream, "| ********************************\n", []),
        printf(NameStream, "|\n", []),
        printf(NameStream, "| This is the C4.5 declaration file for ", []),
        printf(NameStream, "the solve context:\n", []),
        term_string(solve(Prog, Horizon, RewardFunction), ContextString),
        printf(NameStream, "| --------------------------------------", []),
        printf(NameStream, "------------------\n", []),
        printf(NameStream, "| %w\n", [ContextString]),
        printf(NameStream, "| --------------------------------------", []),
        printf(NameStream, "------------------\n", []),
        printf(NameStream, "|\n", []),
        printf(NameStream, "| First we list the possible decisions\n", []),
        printf(NameStream, "| (policy, value, prob, tree),\n", []),
        printf(NameStream, "| separated by commas and terminated by ", []),
        printf(NameStream, "a fullstop.\n", []),
        printf(NameStream, "\n", []),
%%%        Deprecated... we store the policy in a hash table instead.
%%%        %  Replace commas, as C4.5 forbids them in class names.
%%%        term_string(Policy, PolicyString),
%%%        replace_string(PolicyString, ",", "\\,", PolicyStringNoComma),
%%%%        printf(NameStream, "%w", [PolicyStringNoComma]),
%%%        term_string(Value, ValueString),
%%%        term_string(TermProb, TermProbString),
        %  TODO: PolicyTreeString can get too big for
        %        reasonable processing.
        %        We replace it by the placeholder "Tree", as
        %        it only is used for DT-debugging anyway.
%%        term_string(PolicyTree, PolicyTreeString),
%%        replace_string(PolicyTreeString, ",", "\\,", PolicyTreeStringNoComma),
%%%       PolicyTreeStringNoComma = "Tree",
%%%       concat_string(["(", PolicyStringNoComma, " <Value_", ValueString, ">",
%%%       concat_string(["(", PolicyHashKeyString, " <Value_", ValueString, ">",
%%%                      " <TermProb_", TermProbString, ">", 
%%%                      " <PolicyTree_", PolicyTreeStringNoComma, ">)"],
%%%                      DecisionString),
        concat_string(["Policy_", PolicyHashKeyString],
                       DecisionString),
        printf(NameStream, "%w", [DecisionString]),
        printf(NameStream, ".|append policies here|", []),
        printf(NameStream, "\n", []),
        printf(NameStream, "\n", []),
        printf(NameStream, "| Then we list the attributes (fluents) ", []),
        printf(NameStream, "and their domains.\n", []),
        printf(NameStream, "| The domains can be continuous, discrete, ", []),
        printf(NameStream, "or a set of discrete values\n", []),
        printf(NameStream, "| (notated as a comma-separated list).\n", []),
        printf(NameStream, "\n", []),
        ipl_get_all_fluent_names(S, FluentNames),
        %  As we are not given the domain for discrete fluents
        %  by the Readylog programmer, we simply declare the
        %  domain for discrete fluents as discrete with 1000
        %  entries maximum
        ( foreach(Fluent, FluentNames),
          param(NameStream, S)
          do
             nonvar(Fluent),
             bytes_to_term(Fluent, FluentTerm),
             % ( is_cont_fluent(Fluent) -> %  Not really what we are looking
             %                                for. We will use our own test.
             %                                (The test implies that we can
             %                                evaluate the fluent.)
             ( ( is_continuous(Fluent, S) ) ->
                   ( is_projected_fluent(Fluent) ->
                         %  Decipher name stem of n-dimensional fluent.
                         FluentTerm = projected_fluent(I, N, FluentND),
                         bytes_to_term(FluentND, FluentNDT),
                         term_string(FluentNDT, FluentNDTS),
                         term_string(I, IS),
                         term_string(N, NS),
                         concat_string(["dim_", IS, "_of_", NS, "_",
                                       FluentNDTS],
                                       FluentNameForHumans),
                         printf(NameStream, "%w: discrete 1000.\n",
                               [FluentNameForHumans])
                   ;
                      printf(NameStream, "%w: continuous.\n", [FluentTerm])
                   )
             ;
                   ( is_projected_fluent(Fluent) ->
                         %  Decipher name stem of n-dimensional fluent.
                         FluentTerm = projected_fluent(I, N, FluentND),
                         bytes_to_term(FluentND, FluentNDT),
                         term_string(FluentNDT, FluentNDTS),
                         term_string(I, IS),
                         term_string(N, NS),
                         concat_string(["dim_", IS, "_of_", NS, "_",
                                       FluentNDTS],
                                       FluentNameForHumans),
                         printf(NameStream, "%w: discrete 1000.\n",
                               [FluentNameForHumans])
                   ;   
                      %  The fluent is in byte form... we make it human-
                      %  readable now.
                      ( is_prim_fluent(FluentTerm) ->
                         %  Make sure that we can evaluate the fluent.
                         ( exog_fluent(FluentTerm) ->
                            exog_fluent_getValue(FluentTerm, _ValF, S)
                         ;
                            subf(FluentTerm, _ValF, S)
                         ),
                         printf(NameStream, "%w: discrete 1000.\n", [FluentTerm])
                      ;
                         printf(NameStream, "%w: discrete 1000.\n", [FluentTerm]),
                         printf(NameStream, "| WARNING: %w is neither ", [FluentTerm]),
                         printf(NameStream, "cont nor prim!\n,", []),
                         printf(stdout, "*** WARNING ***: %w is neither ", [FluentTerm]),
                         printf(stdout, "cont nor prim!", [])
                      )
                   )
             )
        ),
        close(NameStream).

%  Creates the C4.5 .data file for the solve context with key HashKeyString.
%  Needs the ContextString, FluentNames, and DecisionString from
%  construct_names_file/7 as input.
%  Helper predicate for write_learning_instance/6.
:- mode construct_data_file(++, ++, ++, ++, ++).
construct_data_file( S, HashKeyString, ContextString, FluentNames,
                     DecisionString ) :-
        concat_string(["solve_context_", HashKeyString, ".data"], FileData),
        open(FileData, write, DataStream),
        printf(DataStream, "| ********************************\n", []),
        printf(DataStream, "| * file generated from ReadyLog *\n", []),
        printf(DataStream, "| ********************************\n", []),
        printf(DataStream, "|\n", []),
        printf(DataStream, "| This is the C4.5 instance data file for ", []),
        printf(DataStream, "the solve context:\n", []),
        printf(DataStream, "| ----------------------------------------", []),
        printf(DataStream, "----------------\n", []),
        printf(DataStream, "| %w\n", [ContextString]),
        printf(DataStream, "| ----------------------------------------", []),
        printf(DataStream, "----------------\n", []),
        printf(DataStream, "|\n", []),
        printf(DataStream, "| Each example consists of one line.\n", []),
        printf(DataStream, "| First in this line comes a ", []),
        printf(DataStream, "comma-separated list of the\n", []),
        printf(DataStream, "| fluent values, and then the ", []),
        printf(DataStream, "decision (policy).\n", []),
        printf(DataStream, "\n", []),
                         
        get_all_fluent_values(S, FluentValues),
        %  remove outer brackets []
        fluent_values_to_string(FluentValues, FluentValuesString),

        length(FluentNames, FluentNo),
        length(FluentValues, ValueNo),
        printf(stdout, "%w Fluents, %w Fluent Values\n", [FluentNo, ValueNo]),
        ( ( FluentNo \= ValueNo ) ->
           printf(stdout, "*** Warning: Numbers of fluents and values ", []),
           printf(stdout, "are not the same!\n", [])
        ;
           true
        ),
%        print_list(FluentNames),
%        print_list(FluentValues),
        printf(DataStream, "%w, %w\n", [FluentValuesString, DecisionString]),
        close(DataStream).


%  Continues the C4.5 .names file for the solve context with key HashKeyString.
%  Returns the DecisionString which is needed by continue_data_file/3
%  Helper predicate for write_learning_instance/6.
:- mode continue_names_file(++, ++, ++).
continue_names_file( PolicyHashKeyString, HashKeyString, DecisionString ) :-
        concat_string(["solve_context_", HashKeyString, ".names"], FileName),
        %  Check, if the decision (policy) has been already declared.
        open(FileName, read, NameStreamRead),
        read_string(NameStreamRead, end_of_file, _Length, NameStreamString),
        close(NameStreamRead),
%%%        term_string(Policy, PolicyString),
%%%%        printf(stdout, "PolicyString: %w.\n", [PolicyString]),
%%%        %  replace commas in policy, as C4.5 forbids them in class names
%%%        replace_string(PolicyString, ",", "\\,",
%%%                       PolicyStringNoComma),
%%%        term_string(Value, ValueString),
%%%        term_string(TermProb, TermProbString),
        %  TODO: PolicyTreeString can get too big for
        %        reasonable processing.
        %        We replace it by the placeholder "Tree", as
        %        it only is used for DT-debugging anyway.
%%        term_string(PolicyTree, PolicyTreeString),
%%        replace_string(PolicyTreeString, ",", "\\,", PolicyTreeStringNoComma),
%%%        PolicyTreeStringNoComma = "Tree",
        %  TODO: Only learn the policy! Store some average values in memory
        %  for each of them to provide for extract_consult_results!
        concat_string(["Policy_", PolicyHashKeyString],
                       DecisionString),
        concat_string([DecisionString, ","],
                       DecisionStringAndComma),
        concat_string([DecisionString, "."],
                       DecisionStringAndFullstop),
        ( ( substring(NameStreamString, DecisionStringAndComma, _Pos)
            ;
            substring(NameStreamString, DecisionStringAndFullstop, _Pos) ) ->
           printf(stdout, "Policy already declared.\n", [])
        ;
           printf(stdout, "Declaring policy.\n", []),
           open(FileName, update, NameStream),
           string_length(NameStreamString, NameStreamStringLength),
           substring(NameStreamString, ".|append policies here|",
                     PolicyAppendingPos),
           PolicyAppendingPosLeft is (PolicyAppendingPos - 1),
           substring(NameStreamString, 1, PolicyAppendingPosLeft,
                     NameStreamStringLeft),
           RestLength is (NameStreamStringLength - PolicyAppendingPosLeft),
           substring(NameStreamString, PolicyAppendingPos,
                     RestLength, NameStreamStringRight),
           concat_string([NameStreamStringLeft, ", ", DecisionString,
                          NameStreamStringRight],
                         NameStreamStringNew),
           printf(NameStream, "%w", [NameStreamStringNew]),
           close(NameStream)
        ).

%  Continues the C4.5 .data file for the solve context with key HashKeyString.
%  Needs the DecisionString from continue_names_file/3 as input.
%  Helper predicate for write_learning_instance/6.
:- mode continue_data_file(++, ++, ++).
continue_data_file( S, HashKeyString, DecisionString ) :-
        concat_string(["solve_context_", HashKeyString, ".data"], FileData),
        open(FileData, append, DataStream),
        get_all_fluent_values(S, FluentValues),
        %  remove outer brackets []
        fluent_values_to_string(FluentValues, FluentValuesString),
        printf(DataStream, "%w, %w\n", [FluentValuesString, DecisionString]),
        close(DataStream).


%  Stores a HashList to the hard disk in a File.
:- mode store_hash_list(++, ++).
store_hash_list(HashList, Filename) :-
        not(exists(Filename)),
        !,
        %  Create a new file.
        hash_list(HashList, HashKeys, HashValues),
        open(Filename, write, Stream),
        printf(Stream, "### HashKeys: ###\n", []),
        printf(Stream, "%w\n\n", [HashKeys]),
        printf(Stream, "### HashValues: ###\n", []),
        printf(Stream, "%w\n", [HashValues]),
        close(Stream).

store_hash_list(HashList, Filename) :-
        % File already exists. Delete it and try again.
        delete(Filename),
        store_hash_list(HashList, Filename).


%  Reads the data from the files, puts them
%  into hash lists, and returns those lists.
:- mode create_hash_lists_from_files(-, -, -, -).
create_hash_lists_from_files( PolicyHashTable,
                              PolicyValueHashTable,
                              PolicyTermprobHashTable,
                              PolicyTreeHashTable ) :-
        printf(stdout, "Reading in policies.hash ... ", []),
        flush(stdout),
        open('policies.hash', read, Stream1),
        read_string(Stream1, end_of_line, _, _),
        read_string(Stream1, end_of_line, _, PolicyHashKeysS),
        read_string(Stream1, end_of_line, _, _),
        read_string(Stream1, end_of_line, _, _),
        read_string(Stream1, end_of_line, _, PolicyHashValuesS),
        printf(stdout, "successfully.\n", []),
        close(Stream1),
        printf(stdout, "Creating PolicyHashTable ... ", []),
        hash_create( PolicyHashTable ),
        printf(stdout, "successfully.\n", []), flush(stdout),
        printf(stdout, "Instantiating PolicyHashTable ... ", []),
        term_string(PolicyHashKeys, PolicyHashKeysS),
        term_string(PolicyHashValues, PolicyHashValuesS),
        hash_set_recursively( PolicyHashKeys, PolicyHashValues,
                              PolicyHashTable ),
        printf(stdout, "successfully.\n", []),
        hash_create( PolicyValueHashTable ),
        ( exists('values.hash') ->
           printf(stdout, "Reading in values.hash ... ", []),
           flush(stdout),
           open('values.hash', read, Stream2),
           read_string(Stream2, end_of_line, _, _),
           read_string(Stream2, end_of_line, _, PolicyValueHashKeysS),
           read_string(Stream2, end_of_line, _, _),
           read_string(Stream2, end_of_line, _, _),
           read_string(Stream2, end_of_line, _, PolicyValueHashValuesS),
           close(Stream2),
           printf(stdout, "successfully.\n", []),
           term_string(PolicyValueHashKeys, PolicyValueHashKeysS),
           term_string(PolicyValueHashValues, PolicyValueHashValuesS),
           hash_set_recursively( PolicyValueHashKeys, PolicyValueHashValues,
                                 PolicyValueHashTable )
        ;
           true
        ),
        hash_create( PolicyTermprobHashTable ),
        ( exists('termprobs.hash') ->
           printf(stdout, "Reading in termprobs.hash ... ", []),
           flush(stdout),
           open('termprobs.hash', read, Stream3),
           read_string(Stream3, end_of_line, _, _),
           read_string(Stream3, end_of_line, _, PolicyTermprobHashKeysS),
           read_string(Stream3, end_of_line, _, _),
           read_string(Stream3, end_of_line, _, _),
           read_string(Stream3, end_of_line, _, PolicyTermprobHashValuesS),
           close(Stream3),
           printf(stdout, "successfully.\n", []),
           term_string(PolicyTermprobHashKeys, PolicyTermprobHashKeysS),
           term_string(PolicyTermprobHashValues, PolicyTermprobHashValuesS),
           hash_set_recursively( PolicyTermprobHashKeys, PolicyTermprobHashValues,
                                 PolicyTermprobHashTable )
        ;
           true
        ),
        hash_create( PolicyTreeHashTable ),
        ( exists('trees.hash') ->
           printf(stdout, "Reading in trees.hash ... ", []),
           flush(stdout),
           open('trees.hash', read, Stream4),
           read_string(Stream4, end_of_line, _, _),
           read_string(Stream4, end_of_line, _, PolicyTreeHashKeysS),
           read_string(Stream4, end_of_line, _, _),
           read_string(Stream4, end_of_line, _, _),
           read_string(Stream4, end_of_line, _, PolicyTreeHashValuesS),
           close(Stream4),
           printf(stdout, "successfully.\n", []),
           term_string(PolicyTreeHashKeys, PolicyTreeHashKeysS),
           term_string(PolicyTreeHashValues, PolicyTreeHashValuesS),
           hash_set_recursively( PolicyTreeHashKeys, PolicyTreeHashValues,
                                 PolicyTreeHashTable )
        ;
           true

        ).
        

%  Instantiates the HashTable by iterating through
%  the lists of HashKeys and HashValues and setting each
%  single pair.
:- mode hash_set_recursively(++, ++, ?).
hash_set_recursively( [], [], _HashTable ) :- !.

hash_set_recursively( HashKeys, HashValues, HashTable ) :- 
% printf(stdout, "hash_set_recursively( %w, %w, %w )\n", [HashKeys, HashValues, HashTable]), flush(stdout),
% printf(stdout, "HashKeys: %w\n", [HashKeys]), flush(stdout),
        HashKeys = [Key | RemainingKeys],
% printf(stdout, "Key: %w\n", [Key]), flush(stdout),
        HashValues = [Value | RemainingValues],
% printf(stdout, "hash_set( %w, %w )\n", [Key, Value]), flush(stdout),
        hash_set(HashTable, Key, Value),
        hash_set_recursively(RemainingKeys, RemainingValues,
                             HashTable).



% }}}

% --------------------------------------------------------- %
%  Consultation of Learned Decision Trees                   %
% --------------------------------------------------------- %
% {{{ Consultation of dtrees


%  Consult the decision tree that has been generated by C4.5 for the given
%  solve context.
%  This predicate supplies only those attribute values that C4.5 needs
%  to come to a classification.
%  Returns a Policy together with its Value, TermProb, Tree (for debug output),
%  and a truth value Success to indicate whether the consultation was
%  successful, or it was unsuccessful (and we have to replan).
:- mode consult_dtree(++, ++, ++, ++, -, -, -, -, -). 
consult_dtree( Prog, Horizon, RewardFunction, S,
               Policy, Value, TermProb, Tree, Success) :-
        term_hash(solve(Prog, Horizon, RewardFunction), -1, 1000, HashKey),
        term_string(HashKey, HashKeyString),
        concat_string(["solve_context_", HashKeyString], FileStem),
        consult_dtree_aux( Prog, Horizon, RewardFunction, S, FileStem,
                           Policy, Value, TermProb, Tree, Success).

%  Helper predicate for the decision tree consultation.
%  Takes care of missing file exceptions.
:- mode consult_dtree_aux(++, ++, ++, ++, ++, -, -, -, -, -).
consult_dtree_aux( Prog, Horizon, RewardFunction, S, FileStem,
                   Policy, Value, TermProb, Tree, _Success) :-
        concat_strings(FileStem, ".tree", FileTree),
        not(existing_file(FileStem, [".tree"], [readable], FileTree)),
        !,
        printf(stdout, "[Consultation Phase]: (*** Error ***) ", []),
        printf(stdout, "Decision tree not found!\n", []),
        printf(stdout, "[Consultation Phase]: Consulting ", []),
        printf(stdout, "DT planner instead.\n", []),
        bestDoM(Prog, S, Horizon, Policy,
                Value, TermProb, checkEvents, Tree, RewardFunction).

consult_dtree_aux( Prog, Horizon, RewardFunction, S, FileStem,
                   Policy, Value, TermProb, Tree, _Success) :-
        concat_strings(FileStem, ".names", FileNames),
        not(existing_file(FileStem, [".names"], [readable], FileNames)),
        !,
        printf(stdout, "[Consultation Phase]: (*** Error ***) ", []),
        printf(stdout, "file %w not found!\n", [FileNames]),
        printf(stdout, "[Consultation Phase]: Consulting ", []),
        printf(stdout, "DT planner instead.\n", []),
        bestDoM(Prog, S, Horizon, Policy,
                Value, TermProb, checkEvents, Tree, RewardFunction).

consult_dtree_aux( _Prog, _Horizon, _RewardFunction, S, FileStem,
                   Policy, Value, TermProb, Tree, Success) :-
        canonical_path_name(FileStem, FullPath),
        printf(stdout, "Consulting %w...\n", [FullPath]),
        flush(stdout),
        concat_string([FullPath, ".tree"], FullPathTree),
        ( not(exists(FullPathTree)) ->
            printf(stdout, "Error: %w not found!\n", [FullPathTree])
        ;
            true
        ),
        %  Run the C4.5/Prolog interface as another process.
     %   ( exists('../../libraries/c45_lib/consultobj/ConsultObjectTest2') ->
     %      ConsultObjectTest2 = 
     %         "../../libraries/c45_lib/consultobj/ConsultObjectTest2"
     %   ;
     %      ( exists('/home/drcid/readybot/golog/ipl_agent/libraries/c45_lib/consultobj/ConsultObjectTest2') ->
%        ConsultObjectTest2 = '../golog/ipl_agent/libraries/c45_lib/consultobj/ConsultObjectTest2',
     %      ;
     %         printf(stdout, "ERROR: Didn't find ConsultObjectTest2 executable\n", [])
     %      )
     %   ),
        ( not(exists("../golog/ipl_agent/libraries/c45_lib/consultobj/ConsultObjectTest2")) ->
            printf(stdout, "Error: ../golog/ipl_agent/libraries/c45_lib/consultobj/ConsultObjectTest2 not found!\n", [])
        ;
            true
        ),
        exec(["../golog/ipl_agent/libraries/c45_lib/consultobj/ConsultObjectTest2", "-f",
              FullPath],
             [in, out, err], Pid),
        %  Do the Loop
        %  "C4.5 asks for attribute value ->
        %   Readylog provides Fluent Value ->
        %   C4.5 asks..."
        %  until either C4.5 gives a decision, or the consultation
        %  fails.
        repeat,
           ask_c45_for_decision( in, out, err, S,
                                 DecisionString, Success ),
%        at_eof(out), %  Somehow doesn't work as intended
%                     %  with the pipe stream
%        ( ground(DecisionString) ; ground(Success) ),
        ( nonvar(DecisionString) ; nonvar(Success) ),
        !,
        close(in),
        close(out),
        wait(Pid, _Stat),

        ( ( Success == false ) ->
           true
        ;
            printf(stdout, "[Consultation Phase]: Success == true.. extract...\n", []),
           extract_consultation_results( DecisionString,
                                         Policy, Value, TermProb, Tree ),
            printf(stdout, "[Consultation Phase]: Success\n", []),
           Success = true
        ),

        ( Success ->
            printf(stdout, "[Consultation Phase]: ", []),
            printf(stdout, "Consultation successful!\n", [])
        ;
            printf(stdout, "[Consultation Phase]: ", []),
            printf(stdout, "Consultation failed!\n", [])
        ).


%  Ask C4.5 for a decision. If C4.5 needs more information still, it asks
%  for the value of one attribute with this predicate.
%  The IndicatorStrings with the markers "####" are produced by
%  the (C++) C4.5/Prolog interface library "c45_lib".
:- mode ask_c45_for_decision(++, ++, ++, ++, ?, ?).        
ask_c45_for_decision( in, out, err, S, DecisionString, Success ) :-
%         print_skip( out, "####", IndicatorString ),
        quiet_skip( out, "####", IndicatorString ),
        ask_c45_for_decision_aux( in, out, err, S, IndicatorString,
                                  DecisionString, Success ).

%  Helper predicate for the interprocess communication with C4.5.
%  Is used to differ between different C4.5 outputs.
%  The IndicatorStrings with the markers "####" are produced by
%  the (C++) C4.5/Prolog interface library "c45_lib".
:- mode ask_c45_for_decision_aux(++, ++, ++, ++, ++, -, -).        
ask_c45_for_decision_aux( in, out, err, S, IndicatorString,
                          _DecisionString, _Success ) :-
        substring(IndicatorString,
                  "#### Here comes the attribute name ####", _),
        !,
        read_string(out, end_of_line, _, AttributeNameS),
        term_string(AttributeName, AttributeNameS),
        printf(stdout, "--------\n", []),
        printf(stdout, "[PROLOG] C4.5 asked for the value of attribute: ", []),
        printf(stdout, "%w\n", [AttributeNameS]),
        flush(stdout),
        exog_fluent_getValue(AttributeName, ValTmp, S),
        %  Replace commas, as C4.5 forbids them in
        %  attribute values.
        term_string(ValTmp, ValTmpString),
        replace_string(ValTmpString, ",", "\\,", AttributeValue),
        flush(stdout),
        select([in], 100, _ReadyStream),
%        printf(stdout, "Stream %w ready for I/O.\n", [ReadyStream]),
        flush(stdout),
        printf(in, "%w\n", [AttributeValue]),
        flush(in),
        read_string(out, end_of_line, _, PrologAnswer),
        printf(stdout, "%w\n", [PrologAnswer]),
        flush(stdout).

ask_c45_for_decision_aux( in, out, err, _S, IndicatorString,
                          DecisionString, _Success ) :-
        substring(IndicatorString, "#### Here comes the decision ####", _),
        !,
        printf(stdout, "--------\n", []),
        printf(stdout, "[PROLOG] C4.5 is giving a decision.\n", []),
        flush(stdout),
        read_string(out, end_of_line, _, DecisionString),
%        string_length(Decision, DecisionLength),
%        RawDecisionLength is (DecisionLength - 2),
%        substring(Decision, 2, RawDecisionLength, DecisionString),
        printf(stdout, "[C4.5] Decision: %w\n", [DecisionString]),
        printf(stdout, "--------\n", []),
        flush(stdout),
        ( ( stream_ready(out), not(at_eof(out) ) ) ->
           read_string(out, end_of_file, _, _Rest)
        ;
           true
        ).

ask_c45_for_decision_aux( in, out, err, _S, IndicatorString,
                          _DecisionString, Success ) :-
        %  Happens when the attribute value has not been seen during
        %  training.
        substring(IndicatorString, "#### Error ####", _), !,
        printf(stdout, "--------\n", []),
        printf(stdout, "[C4.5] This attribute value has not appeared ", []),
        printf(stdout, "during training.\n", []),
        printf(stdout, "       Will use planning instead.\n", []),
        printf(stdout, "--------\n", []),
        Success = false,
        flush(stdout),
        ( ( stream_ready(out), not(at_eof(out) ) ) ->
           read_string(out, end_of_file, _, _Rest)
        ;
           true
        ).

ask_c45_for_decision_aux( in, out, err, _S, _IndicatorString,
                          _DecisionString, Success ) :-
        printf(stdout, "--------\n", []),
        printf(stdout, "[C4.5] Error: This should not happen. ", []),
        printf(stdout, "Error in parsing?\n", []),
        printf(stdout, "--------\n", []),
        Success = false,
        flush(stdout),
        ( ( stream_ready(out), not(at_eof(out) ) ) ->
           read_string(out, end_of_file, _, _Rest)
        ;
           true
        ).


%  From the classification DecisionString, extract the policy.
%  The DecisionString is "Policy_x", where x is the hash key of
%  the policy.
:- mode extract_consultation_results(++, -, -, -, -).
extract_consultation_results( DecisionString,
                              Policy, Value, TermProb, Tree ) :-
         %%%  Cut out hash key for Policy.  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         printf(stdout, "DecisionString: %w\n", [DecisionString]), flush(stdout),
         append_strings("Policy_", PolicyHashKeyString, DecisionString),
         printf(stdout, "PolicyHashKeyString: %w\n", [PolicyHashKeyString]), flush(stdout),
         term_string(PolicyHashKey, PolicyHashKeyString),
         printf(stdout, "PolicyHashKey: %w\n", [PolicyHashKey]), flush(stdout),
         %%%  Get the necessary information from the hash tables.  %%%%%%%%%
         getval(policy_hash_table, PolicyHashTable),
         ( not(hash_contains(PolicyHashTable, PolicyHashKey)) ->
            printf(stdout, "Error: No hash entry for this PolicyHashKey in PolicyHashTable!\n", []), flush(stdout)
         ;
            hash_get(PolicyHashTable, PolicyHashKey, Policy),
            printf(stdout, "Policy: %w\n", [Policy]), flush(stdout)
         ),

         getval(policy_value_hash_table, PolicyValueHashTable),
         hash_get(PolicyValueHashTable, PolicyHashKey, Value),
         printf(stdout, "Value: %w\n", [Value]), flush(stdout),

         getval(policy_termprob_hash_table, PolicyTermprobHashTable),
         hash_get(PolicyTermprobHashTable, PolicyHashKey, TermProb),
         printf(stdout, "TermProb: %w\n", [TermProb]), flush(stdout),

         getval(policy_tree_hash_table, PolicyTreeHashTable),
         hash_get(PolicyTreeHashTable, PolicyHashKey, Tree),
         printf(stdout, "Tree: %w\n", [Tree]), flush(stdout).

%% DEPRECATED %%
/*        
%  From the classification DecisionString, extract the policy, 
%  its Value, TermProb, and Tree.
%  They are encoded in the string by markers
%  <Value_x> <TermProb_y> <PolicyTree_z>, where x, y, z stand for the
%  stored values that we are interested in.
%  The actual policy does not have a marker; it just is located
%  in front of the value-marker.
:- mode extract_consultation_results(++, -, -, -, -).
extract_consultation_results( DecisionString,
                              Policy, Value, TermProb, Tree ) :-
         %%%  Cut out Policy.  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         substring(DecisionString, ValuePos, 7, "<Value_"),
         ValuePosLeft is (ValuePos - 2),
         substring(DecisionString, 1, ValuePosLeft, PolicyString),
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         %%%  Cut out Value.  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         string_length(PolicyString, PolicyLength),
         string_length(DecisionString, DecisionStringLength),
         BeyondPolicyLength is ( DecisionStringLength
                                - PolicyLength - 1),
         PolicyEndRight is (PolicyLength + 2),
         substring(DecisionString, PolicyEndRight, BeyondPolicyLength,
                   BeyondPolicy),
         substring(BeyondPolicy, ValueEndPos, 12, "> <TermProb_"),
%         printf("BeyondPolicy: %w\n", [BeyondPolicy]),
         ValueLength is (ValueEndPos - 8),
         substring(BeyondPolicy, 8, ValueLength, ValueString),
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

         %%%  Cut out TermProb.  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         ValueEndPosRight is (ValueEndPos + 2),
         BeyondValueLength is ( BeyondPolicyLength
                                - ValueLength - 9 ),
         substring(BeyondPolicy, ValueEndPosRight, BeyondValueLength,
                   BeyondValue),
%         printf("BeyondValue: %w\n", [BeyondValue]),
         substring(BeyondValue, TermProbEndPos, 14, "> <PolicyTree_"),
         TermProbLength is (TermProbEndPos - 11),
         substring(BeyondValue, 11, TermProbLength, TermProbString),
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

         %%%  Cut out Tree.  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         TermProbEndPosRight is (TermProbEndPos + 2),
         BeyondTermProbLength is ( BeyondValueLength
                                   - TermProbLength - 12 ),
         substring(BeyondValue, TermProbEndPosRight, BeyondTermProbLength,
                   BeyondTermProb),
%         printf("BeyondTermProb: %w\n", [BeyondTermProb]),
         substring(BeyondTermProb, TreeEndPos, 1, ">"),
         TreeLength is (TreeEndPos - 13),
         substring(BeyondTermProb, 13, TreeLength, TreeString),
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%         printf("Policy: %w\n", [Policy]),
%         printf("Value: %w\n", [Value]),
%         printf("TermProb: %w\n", [TermProb]),
%         printf("Tree: %w\n", [Tree]),
%         flush(stdout),
%%%         term_string(Policy, PolicyString),
         %  Recover the policy from the hash table.
         getval(policy_hash_table, PolicyHashTable),
         term_string(PolicyHashKey, PolicyString),
         hash_get(PolicyHashTable, PolicyHashKey, Policy),
         term_string(Value, ValueString),
         term_string(TermProb, TermProbString),
         term_string(Tree, TreeString).

%% /DEPRECATED %%
*/

% }}}
