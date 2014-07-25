open Tools
open Mods
open State
open Random_tree
(***)
open Mpi
open Spatial_eval
open Communication



(***)

let version = "1.0"

let usage_msg = "PISKa "^version^" (based on KaSim version 3.5-160514): \n"^"Usage is $ [mpirun* -np n_comparts] PISKa -i input_file [-e events] -t time [-p points] -sync-t s_time\n" (*^ "process number:"^(string_of_int myrank)*)
let version_msg = "Parallel Spatial Kappa Simulator: "^version^" (based on KaSim version 3.1-191112)\n"

let close_desc opt_env =
	List.iter (fun d -> close_out d) !Parameter.openOutDescriptors ;
	List.iter (fun d -> close_in d) !Parameter.openInDescriptors ;
	match opt_env with
		| None -> ()
		| Some env -> Environment.close_desc env

let main =
	let options = [
		("--version", Arg.Unit (fun () -> print_string (version_msg^"\n") ; flush stdout ; exit 0), "display KaSim version");
		("-i", Arg.String (fun fic -> Parameter.inputKappaFileNames:= fic:: (!Parameter.inputKappaFileNames)),
			"name of a kappa file to use as input (can be used multiple times for multiple input files)");
		("-e", Arg.Int (fun i -> if i < 0 then Parameter.maxEventValue := None else Parameter.maxTimeValue:= None ; Parameter.maxEventValue := Some i) ,
			"Number of total simulation events, including null events (negative value for unbounded simulation)");
		("-t", Arg.Float(fun t -> Parameter.maxTimeValue := Some t ; Parameter.maxEventValue := None), "Max time of simulation (arbitrary time unit)");
		("-p", Arg.Int (fun i -> Parameter.plotModeOn := true ; Parameter.pointNumberValue:= Some i), "Number of points in plot");
		("-o", Arg.String (fun s -> Parameter.outputDataName:=s ), "file name for data output (deprecated, by default setted to comp_name(proc_id).out") ;
		("-d", 
		Arg.String 
			(fun s -> 
				try 
					if Sys.is_directory s then Parameter.outputDirName := s 
					else (Printf.eprintf "'%s' is not a directory\n" s ; exit 1)  
				with Sys_error msg -> (*directory does not exists*) 
					(Printf.eprintf "%s\n" msg ; exit 1)
			), "Specifies directory name where output file(s) should be stored") ;
		("-load-sim", Arg.String (fun file -> Parameter.marshalizedInFile := file) , "load simulation package instead of kappa files") ; 
		("-make-sim", Arg.String (fun file -> Parameter.marshalizedOutFile := file) , "save kappa files as a simulation package") ; 
		("--implicit-signature", Arg.Unit (fun () -> Parameter.implicitSignature := true), "Program will guess agent signatures automatically") ;
		("-seed", Arg.Int (fun i -> Parameter.seedValue := Some i), "Seed for the random number generator") ;
		("--eclipse", Arg.Unit (fun () -> Parameter.eclipseMode:= true), "enable this flag for running KaSim behind eclipse plugin") ;
		("--emacs-mode", Arg.Unit (fun () -> Parameter.emacsMode:= true), "enable this flag for running KaSim using emacs-mode") ;
		("--compile", Arg.Unit (fun _ -> Parameter.compileModeOn := true), "Display rule compilation as action list") ;
		("--debug", Arg.Unit (fun () -> Parameter.debugModeOn:= true), "Enable debug mode") ;
		("--safe", Arg.Unit (fun () -> Parameter.safeModeOn:= true), "Enable safe mode") ;
		("--backtrace", Arg.Unit (fun () -> Parameter.backtrace:= true), "Backtracing exceptions") ;
		("--gluttony", Arg.Unit (fun () -> Gc.set { (Gc.get()) with Gc.space_overhead = 500 (*default 80*) } ;), "Lower gc activity for a faster but memory intensive simulation") ;
		("-rescale-to", Arg.Int (fun i -> Parameter.rescale:=Some i), "Rescale initial concentration to given number for quick testing purpose") ; 
  		("-sync-t", Arg.Float (fun t -> Parameter.syncTime := t ), "Simulation time to Synchronize threads (ie. messaging / transport)");
 	] 
	in
	begin
	try
		Arg.parse_argv Sys.argv options (fun _ -> if  myrank = 0 then Arg.usage options usage_msg ; exit 1) usage_msg 
	with 
		| Arg.Help s | Arg.Bad s -> 
			if  myrank = 0 then
				Arg.usage options usage_msg ;
			exit 1
	end;
	try
		if  myrank = 0 then begin
		if not !Parameter.plotModeOn then ExceptionDefn.warning "No data points are required, use -p option for plotting data.";
		let abort =
			match !Parameter.inputKappaFileNames with
			| [] -> if !Parameter.marshalizedInFile = "" then true else false
			| _ -> false
		in
		if abort then (prerr_string usage_msg ; raise (Mpi.Error "No data. Aborting..") ) ;
		let sigint_handle = fun _ ->
			raise (ExceptionDefn.UserInterrupted (fun t -> fun e -> Printf.sprintf "Abort signal received after %E t.u (%d events)" t e))
		in
		let _ = Sys.set_signal Sys.sigint (Sys.Signal_handle sigint_handle) in
		
		Printexc.record_backtrace !Parameter.backtrace ; (*Possible backtrace*)
		
		(*let _ = Printexc.record_backtrace !Parameter.debugModeOn in*) 
		end;
		let compils =
			if  myrank = 0 then 
				let result_g = 
					Ast.init_compil_glob() ;
					List.iter (fun fic -> let _ = KappaLexer.compile fic in ()) !Parameter.inputKappaFileNames ;
					!Ast.result_glob
				in
					Spatial_eval.initialize_glob result_g;
			else
				[];
		in
		check_mpi_processes 0 "Parsing Globals: Ok";
		
		(*Receive random seed from root if given*)
		(*Initialize local random number generator*)
		let (_: unit) = 
			match !Parameter.seedValue with
			| Some seed -> 
				let seed_array =
					if myrank = 0 then
					begin
						Random.init seed;
						Array.map Random.bits (Array.make world_size ())
					end
					else [||]
				in let local_seed =
					scatter seed_array 0 comm_world
				in
					Random.set_state (Random.State.make (Array.make 1 local_seed))
			| None -> 
			begin
				if myrank = 0 then Printf.printf "+ Self seeding...\n" ;
				Random.self_init() ;
				let i = Random.bits () in
				Random.set_state (Random.State.make (Array.make 1 i ) );
				if myrank = 0 then Printf.printf "+ Initialized random number generator with seed %d\n" i
			end
		in
		
		let counter =	Counter.create 0.0 0 !Parameter.maxTimeValue !Parameter.maxEventValue !Parameter.syncTime in
		
		let comp_id, dims, env, state = 
			match !Parameter.marshalizedInFile with
				| "" -> (** RECEIVE RESULT **)
					if myrank = 0 && List.length compils != world_size then
						raise (Mpi.Error "Mpi processes quantity must be equal to compartments.");
					check_mpi_processes 0 "Mpi options: Ok";
					let (comp_id,result) = scatter (Array.of_list compils) 0 comm_world in
					let env,state = Eval.initialize result counter
					in comp_id,result.Ast.dims,env,state
				| marshalized_file ->
				try
					let d = open_in_bin marshalized_file 
					in begin
						if myrank = 0 then 
							if !Parameter.inputKappaFileNames <> [] then 
								Printf.printf "+ Loading simulation package %s (kappa files are ignored)...\n" marshalized_file 
							else 
								Printf.printf "+Loading simulation package %s...\n" marshalized_file ;
						let sim_pack_arr = 
							if myrank = 0 then begin
								let pack = (Marshal.from_channel d : 
									((string * int) * (int list) * Environment.t * State.implicit_state) array ) in
								if Array.length pack != world_size then
									raise (Mpi.Error "Mpi processes quantity must be equal to compartments.");
								pack
							end
							else [||]
						in
						Pervasives.close_in d ;
						check_mpi_processes 0 "Mpi options: Ok";
						let comp_id,dims,env,state = scatter sim_pack_arr 0 comm_world in
						if myrank = 0 then Printf.printf "Done\n" ;
						comp_id,dims,env,state 
					end
				with
				| exn ->
					raise exn(*(Mpi.Error "!Simulation package seems to have been created with a different version of KaSim, aborting..."); *)
		in
		check_mpi_processes 0 "Eval local: Ok";
		Parameter.setOutputName() ; (*changin output names if -d option was used*)
		(*Parameter.checkFileExists() ;*)
		
		let (_:unit) = 
			match !Parameter.marshalizedOutFile with
				| "" -> ()
				| file -> 
					let d = open_out_bin file 
					in begin
						let sim_pack_arr = gather (comp_id,dims,env,state) 0 comm_world in
						Marshal.to_channel d sim_pack_arr [Marshal.Closures] ;
						close_out d
					end
		in (* _:unit *)
		
		(* Assign comp-name -> process-rank*)
		let comp_map =
			Array.fold_left (fun tbl (name,rank) ->
				Hashtbl.add tbl name rank;
				tbl
			) (Hashtbl.create world_size) (allgather (comp_id,myrank) comm_world)
		in
		
		
		if !Parameter.influenceFileName <> ""  then 
			begin
				let desc = open_out !Parameter.influenceFileName in
				State.dot_of_influence_map desc state env ; 
				close_out desc 
			end ;  
		if !Parameter.compileModeOn then (Hashtbl.iter (fun i r -> Dynamics.dump r env) state.State.rules ; exit 0)
		else () ;
    let profiling = Compression_main.D.S.PH.B.PB.CI.Po.K.P.init_log_info () in 
    	let fname = Spatial_util.string_of_comp ~dims_opt:(dims) comp_id in
		let plot = Plot.create (Filename.concat !Parameter.outputDirName (fname ^".out"))
		and grid,profiling,event_list = 
			if Environment.tracking_enabled env then
				let _ = 
					if !Parameter.mazCompression || !Parameter.weakCompression || !Parameter.strongCompression then ()
					else (ExceptionDefn.warning "Causal flow compution is required but no compression is specified, will output flows with no compresion"  ; 
					Parameter.mazCompression := true)
				in  
				let grid = Causal.empty_grid() in 
                                let event_list = [] in 
                                let profiling,event_list = 
                                Compression_main.D.S.PH.B.PB.CI.Po.K.store_init profiling state event_list in 
                                grid,profiling,event_list
                        else (Causal.empty_grid(),profiling,[])
		in
		ExceptionDefn.flush_warning () ; 
		Parameter.initSimTime () ; 
		
		if myrank = 0 then (
		Hashtbl.iter (fun (name,cnum) id ->
			Debug.tag (Printf.sprintf "%s_%d -> %d" name cnum id)
		) comp_map);
		
		(* synch for parser errors *)
		check_mpi_processes 0 "Evaluating Locals: Ok";
		
		try
						
(**HERE**)	Run.loop state profiling event_list counter plot env comp_id comp_map; (** HERE **)
	
			Mpi.barrier comm_world;
			if myrank = 0 then Spatial_util.show_timer ();
			let output_string = 
				[| format_of_string "\t#Valid embedding but no longer unary when required: %f\n" ;
					format_of_string "\t#Valid embedding but not binary when required: %f\n" ;
					format_of_string "\t#Clashing instance: %f\n" ;
					format_of_string "\t#Lazy negative update: %f\n"	;
					format_of_string "\t#Lazy negative update of non local instances: %f\n" ;
					format_of_string "\t#Perturbation interrupting time advance: %f\n" 
				|]
			and sim_data_local = Array.make 8 0.0 
			and sim_data_global = Array.make 8 0.0 in
			(match plot.Plot.desc with
				| None -> ()
				| Some d ->
					Printf.fprintf d "\n#Simulation ended (eff.: %f, detail below)\n" 
							((float_of_int (Counter.event counter)) /. 
							(float_of_int (Counter.null_event counter + Counter.event counter))) ;
					Printf.fprintf d "\t#Events: %d\n" (Counter.event counter);
					sim_data_local.(6) <- float_of_int (Counter.event counter);
					sim_data_local.(7) <- ((float_of_int (Counter.event counter)) /. 
							(float_of_int (Counter.null_event counter + Counter.event counter)));
					Array.iteri (fun i n ->
						match i with
						| 0 | 1 | 2 | 3 | 4 | 5 -> 
							sim_data_local.(i) <- (((float_of_int n) /. (float_of_int (Counter.null_event counter))));
							Printf.fprintf d output_string.(i) sim_data_local.(i)
						| _ -> Printf.fprintf d "\t#na\n"
					) counter.Counter.stat_null 
				);
			reduce_float_array sim_data_local sim_data_global Float_sum 0 comm_world;
			if myrank = 0 then begin
				Printf.printf "\n#Simulation ended (eff.: %f, detail below)\n" 
							sim_data_global.(7) ;
				Printf.printf "\t#Events: %d\n" (int_of_float sim_data_global.(6));
				Array.iteri (fun i n ->
					match i with
					| 0 | 1 | 2 | 3 | 4 | 5 ->
						Printf.printf output_string.(i) sim_data_global.(i) 
					| _ -> print_string "\tna\n"
				) counter.Counter.stat_null ;
			end;
			if !Parameter.fluxModeOn then 
				begin
					let d = open_out !Parameter.fluxFileName in
					State.dot_of_flux d state env ;
					close_out d
				end 
			else () ;
		with (*try loop*)
			| ex -> (* propagate Error *)
				Communication.propagate_error "error";
				try raise ex with
			| Invalid_argument msg -> 
				begin
					(*if !Parameter.debugModeOn then (Debug.tag "State dumped! (dump.ka)" ; let desc = open_out "dump.ka" in State.snapshot state counter desc env ; close_out desc) ; *)
				  let s = (* Printexc.get_backtrace() *) "" in Printf.eprintf "\n***Runtime error %s***\n%s\n" msg s ;
					exit 1
				end
			| ExceptionDefn.UserInterrupted f -> 
				begin
					flush stdout ; 
					let msg = f (Counter.time counter) (Counter.event counter) in
					Printf.eprintf "\n***%s: would you like to record the current state? (y/N)***\n" msg ; flush stderr ;
					(match String.lowercase (Tools.read_input ()) with
						| "y" | "yes" ->
							begin 
								Parameter.dotOutput := false ;
								let desc = open_out !Parameter.dumpFileName in 
								State.snapshot state counter desc !Parameter.snapshotHighres env ;
								Parameter.debugModeOn:=true ; State.dump state counter env ;
								close_out desc ;
								Printf.eprintf "Final state dumped (%s)\n" !Parameter.dumpFileName
							end
						| _ -> ()
					) ;
					close_desc (Some env) (*closes all other opened descriptors*)
				end
			| ExceptionDefn.Deadlock ->
				(Debug.tag (Printf.sprintf "?\nA deadlock was reached after %d events and %Es (Activity = %.5f)\n"
				(Counter.event counter)
				(Counter.time counter) 
				(Random_tree.total state.activity_tree)))
	with  (*try parse*)
	| ex ->
		check_mpi_processes 1 "";
		try raise ex with
	| ExceptionDefn.Semantics_Error (pos, msg) -> 
		(close_desc None ; Printf.eprintf "***Error (%s) line %d, char %d: %s***\n" (fn pos) (ln pos) (cn pos) msg)
	| Invalid_argument msg -> 
		(close_desc None; let s = "" (*Printexc.get_backtrace()*) in Printf.eprintf "\n***Runtime error %s***\n%s\n" msg s)
	| ExceptionDefn.UserInterrupted f -> 
		let msg = f 0. 0 in 
		(Printf.eprintf "\n***Interrupted by user: %s***\n" msg ; close_desc None)
	| ExceptionDefn.StopReached msg -> 
		(Printf.eprintf "\n***%s***\n" msg ; close_desc None)
	| Sys_error msg -> 
		(close_desc None; Printf.eprintf "***Error: %s\n" msg)
	| Mpi.Error msg ->
		(close_desc None; Printf.eprintf "***Error: %s\n" msg)
	
	
