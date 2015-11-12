(* 
COMPILE WITH:
ocamlfind ocamlc -g -thread -package lablgtk2 -package async -linkpkg info.mli game.mli gui.ml game.ml  -o game
*)

open Async.Std 
open Info

let locale = GtkMain.Main.init () 

let current_state = ref (Ivar.create ())

let handle_preprocessing gs = failwith "TODO"

let handle_action g2 cmd1 cmd2 = failwith "TODO"

let quit thread_list = 
	let _ = List.map Thread.kill thread_list in Thread.exit () 

let give_gui_permission () = current_state := Ivar.create ()

let wait_for_command () = 
	while Ivar.is_empty !current_state do 
		() 
	done 

let main () = 
	let scheduler_thread = Thread.create Scheduler.go () in 
	let gui_thread = Thread.create (Gui.main_gui current_state) () in 
	let rec game_loop () = 
		let () = wait_for_command () in 
		upon (Ivar.read !current_state) (fun state ->
			match state with 
			| MainMenu -> game_loop () 
			| Menu1P -> game_loop () 
			| Quit -> quit [gui_thread; scheduler_thread]
		)
	in game_loop () 

let _ = main () 