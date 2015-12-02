open Async.Std
open Info
open Pokemon

(* All pokemon IVs in this game will be max at 31 *)
let pokeIV = 31

let prevmove1 = ref ""
let prevmove2 = ref ""

(* Peeks into the Ivar for the game state *)
let get_game_status engine =
  match Deferred.peek (Ivar.read !engine) with
  | Some v -> v
  | None -> failwith "Faulty game logic"

(* Decode the instructions sent by the gui *)
let unpack opt =
  match opt with
  | Some v -> v
  | None -> AIMove

(* Status of Pokemon is changed after switching out *)
let switchOutStatus bpoke =
  match bpoke.curr_status with
  | (x, _) -> (match x with
              | Toxic _ -> (Toxic 0, [])
              | _ -> (x, []))

(* Stat enhancements are lost after switching out (except for some edge cases)*)
let switchOutStatEnhancements t =
  {attack=(0,1.); defense=(0,1.); speed=(0,1.); special_attack=(0,1.);
  special_defense=(0,1.); evasion=(0,1.); accuracy=(0,1.)}

(* Turns a pokemon into a battle poke *)
let getBattlePoke poke =
  let bhp = (2 * poke.hp + pokeIV + poke.evs.hp / 4) + 100 + 10 in
  (* Changes value of stat based upon Nature of Pokemon *)
  let battack = int_of_float ((match poke.nature with
    | Lonely | Adamant | Naughty | Brave -> 1.1
    | Bold | Modest | Calm | Timid -> 0.9
    | _ -> 1.0) *. float_of_int
            (2 * poke.attack + pokeIV + poke.evs.attack / 4 + 5)) in
  let bdefense = int_of_float ((match poke.nature with
    | Bold | Impish | Lax | Relaxed -> 1.1
    | Lonely | Mild | Gentle | Hasty -> 0.9
    | _ -> 1.0) *.  float_of_int
            (2 * poke.defense + pokeIV + poke.evs.defense / 4 + 5)) in
  let bspecial_attack = int_of_float ((match poke.nature with
    | Modest | Mild | Rash | Quiet -> 1.1
    | Adamant | Impish | Careful | Jolly -> 0.9
    | _ -> 1.0) *.  float_of_int (2 * poke.special_attack +
              pokeIV + poke.evs.special_attack / 4 + 5)) in
  let bspecial_defense = int_of_float ((match poke.nature with
    | Calm | Gentle | Careful | Sassy -> 1.1
    | Naughty | Lax | Rash | Naive -> 0.9
    | _ -> 1.0) *.  float_of_int (2 * poke.special_defense +
              pokeIV + poke.evs.special_defense / 4 + 5)) in
  let bspeed = int_of_float ((match poke.nature with
    | Timid | Hasty | Jolly | Naive -> 1.1
    | Brave | Relaxed | Quiet | Sassy -> 0.9
    | _ -> 1.0) *.  float_of_int (2 * poke.speed + pokeIV +
              poke.evs.speed / 4 + 5)) in
  (* Returns the new battle pokemon as a record *)
  {pokeinfo = poke; curr_hp = bhp; curr_status = (NoNon, []);
  curr_item = poke.item; bhp; battack; bdefense; bspecial_attack;
  bspecial_defense; bspeed}

(* Initializes the game state *)
let initialize_battle team1 team2 =
  team1.current <- getBattlePoke (getTestPoke ());
  team2.current <- getBattlePoke (getTestOpp ()); Battle (InGame
    (team1, team2, {weather = ClearSkies; terrain = {side1= ref []; side2= ref []}}, ref (Pl1 NoAction), ref (Pl2 NoAction)))

(* Gets a random team of pokemon for initialization *)
let getRandomTeam () =
  let stat_enhance = {attack=(0,1.); defense=(0,1.); speed=(0,1.);
      special_attack=(0,1.); special_defense=(0,1.); evasion=(0,1.);
      accuracy=(0,1.)} in
  {current = (getBattlePoke(getRandomPokemon ()));
  dead =[]; alive = (List.map getBattlePoke
  (List.map getRandomPokemon [();();();();()])); stat_enhance}

(* This function returns the accuracy/evasion bonus given by the stages.
   Pre-condition: num is between -6 and 6
   Equation given by Bulbapedia on Statistics article *)
let getStageEvasion num =
  if abs(num) > 6 then failwith "Faulty Game Logic: Debug 43";
  if num <= 0 then
    3. /. float_of_int (- 1 * num + 3)
  else
    float_of_int (num + 3) /. 3.

(* This function returns the accuracy/evasion bonus given by the stages.
   Pre-condition: num is between -6 and 6
   Equation given by Bulbapedia on Statistics article *)
let getStageAD num =
  if abs(num) > 6 then failwith "Faulty Game Logic: Debug 42";
  if num <= 0 then
    2. /. float_of_int (-1 * num + 2)
  else
    float_of_int (num + 2) /. 2.

(* Gets the crit chance based upon the stages.
   Pre-condition: num is greater than 0
   Equation given by Bulbapedia on Critical Strikes article *)
let getCrit poke move =
  let rec helper_crit acc eff = match eff with
  | IncCrit n -> n + acc
  | _ -> 0 in
  let stage = List.fold_left helper_crit 0 move.secondary in
  match stage with
  | 0 -> if (0.0625 > Random.float 1.) then
            (true, 1.5)
          else
            (false, 1.)
  | 1 -> if (0.125 > Random.float 1.) then
            (true, 1.5)
          else
            (false, 1.)
  | 2 -> if (0.50 > Random.float 1.) then
            (true, 1.5)
          else
            (false, 1.)
  | n -> if n >= 3 then (true, 1.5) else (false, 1.)

let get_weather_amplifier w (move : move) =
  match w with
  | Sun _ -> (match move.element with
                        | Water -> 0.5
                        | Fire -> 1.5
                        | _ -> 1.0)
  | Rain _ -> (match move.element with
                        | Water -> 1.5
                        | Fire -> 0.5)
  | _ -> 1.0

(* Damage calculation following the equation given by Bulbapedia.
   Stat boosts are taken into account in the beginning *)
let damageCalculation t1 t2 (w,ter1, ter2) move =
  let defense = match move.dmg_class with
    | Physical ->
      let rec findReflect ter = match ter with
      | [] -> false
      | (Reflect _)::t -> true
      | h::t -> findReflect t in
      (match findReflect !ter2 with
      | true -> 2.0
      | false -> 1.0) *.
      float_of_int t2.current.bdefense *.
      getStageAD (fst t2.stat_enhance.defense) *.
      (snd t2.stat_enhance.defense)
    | Special ->
      let rec findLightScreen ter = match ter with
      | [] -> false
      | (LightScreen _)::t -> true
      | h::t -> findLightScreen t in
      (match findLightScreen !ter2 with
      | true -> 2.0
      | false -> 1.0) *.
      (match w with
      | SandStorm _ -> if (List.mem Rock t2.current.pokeinfo.element) then 1.5 else 1.0
      | _ -> 1.0) *.
      float_of_int t2.current.bspecial_defense *.
      getStageAD (fst t2.stat_enhance.special_defense) *.
      (snd t2.stat_enhance.special_defense)
    | _ -> failwith "Faulty Game Logic: Debug 44" in
  let attack = match move.dmg_class with
    | Physical ->
      float_of_int t1.current.battack *.
      getStageAD (fst t1.stat_enhance.attack) *.
      (snd t1.stat_enhance.attack)
    | Special ->
      float_of_int t1.current.bspecial_attack *.
      getStageAD (fst t1.stat_enhance.special_attack) *.
      (snd t1.stat_enhance.special_attack) in
  let crit_bool, crit  = getCrit t1.current move in
  let type_mod = List.fold_left (fun acc x -> acc *. getElementEffect
      move.element x) 1. t2.current.pokeinfo.element in
  let weather_amplifier = get_weather_amplifier w move in
  let modifier =
      (* type effectiveness *)
      type_mod *.
      (* STAB bonus *)
      if (List.mem move.element t1.current.pokeinfo.element) then 1.5 else 1. *.
      (* Crit bonus *)
      crit *.
      (* weather bonus *)
      weather_amplifier *.
      (* Random fluctuation in power *)
      (Random.float 15. +. 85.) /. 100. in
  let newMove =
    if (crit_bool) then
      if (type_mod > 1.) then
        SEff (Crit (NormMove move.name))
      else if (type_mod < 1. && type_mod > 0.) then
        NoEff (Crit (NormMove move.name))
      else if (type_mod = 0.) then
        NoEffAll (move.name)
      else
        Crit (NormMove move.name)
    else
      if (type_mod > 1.) then
        SEff (NormMove move.name)
      else if (type_mod < 1. && type_mod > 0.) then
        NoEff (NormMove move.name)
      else if (type_mod = 0.) then
        NoEffAll (move.name)
      else
        NormMove move.name in
  Printf.printf "%d\n%!" (int_of_float type_mod);
  ( newMove, (210. /. 250. *. attack /. defense*. float_of_int move.power
    +. 2.)*. modifier)

(* Gets the speed multiplier based on current team conditions *)
let findSpeedMult t =
  if fst (t.current.curr_status) = Paralysis then
    0.25
  else
    1.

(* Gets the attack multiplier based on current team conditions *)
let findAttackMult t =
  if fst (t.current.curr_status) = Burn then
    0.5
  else
    1.

(* Gets the stat multipliers based on current conditions -- recomputed before
  every move is made *)
let recomputeStat t =
  let stats = t.stat_enhance in
  let attack_mult = findAttackMult t in
  let speed_mult = findSpeedMult t in
  stats.attack <- (fst stats.attack, attack_mult);
  stats.speed <- (fst stats.speed, speed_mult)

(* Finds the Pokemon within a list of Battle Pokemon. Typically used to select
  a Pokemon within the list of alive Pokemon for switching out. Returns the
  switched out pokemon as well as the rest of the list. *)
let findBattlePoke lst name =
  let rec helper acc lst =
    match lst with
    | [] -> failwith ("Faulty Game Logic: Debug " ^ name)
    | h::t -> if h.pokeinfo.name = name then h, (acc @ t) else helper (h::acc)
              t in
  helper [] lst

(* Finds a random pokemon and returns name of Pokemon*)
let getRandomPoke t =
  let n = List.length t.alive in
  let num = Random.int n in
  (List.nth t.alive num).pokeinfo.name

(* Finds the move of the pokemon based upon a string that is the move's name*)
let findBattleMove poke move =
  if (poke.move1.name = move) then
    poke.move1
  else if (poke.move2.name = move) then
    poke.move2
  else if (poke.move3.name = move) then
    poke.move3
  else if (poke.move4.name = move) then
    poke.move4
  else
    failwith "Faulty Game Logic: Debug 16"

(* Helper function to fix confusion *)
let decrementConfusion atk =
  let nonvola, vola = atk.curr_status in
  let rec helper acc lst = match lst with
  | (Confusion n)::t when n <= 0 -> acc @ t
  | (Confusion n)::t -> acc @ ((Confusion(n-1))::t)
  | h::t -> helper (h::acc) t
  | [] -> acc in
  let newvola = helper [] vola in
  atk.curr_status <- (nonvola, newvola)

let rec filter_substitute n lst =
  match lst with
  | (Substitute _)::t -> if n = 0 then t else (Substitute n)::t
  | h::t -> h::(filter_substitute n t)
  | [] -> []

(* Helper function to see if pokemon can move; also called to break a Pokemon
  out of a status condition *)
let hitMoveDueToStatus atk moveDescript =
  let rec helperVolaStatus lst moveDescript' =
    match lst with
      | [] -> (true, moveDescript')
      | Charge::t -> helperVolaStatus t moveDescript'
      | Flinch::t -> (false, `Flinch)
      | (Confusion n)::t ->
            (* n cannot be less than 0 -- invariant *)
            decrementConfusion atk.current;
            (if n = 0 then
                helperVolaStatus t (`BreakConfuse moveDescript')
            else
              (if Random.int 100 > 50 then
                helperVolaStatus t moveDescript'
              else
                (let confuse_damage = int_of_float
                    (42. *. float_of_int atk.current.battack *.
                     getStageAD (fst atk.stat_enhance.attack) *.
                    (snd atk.stat_enhance.attack) *. 0.8 /.
                    (float_of_int atk.current.bdefense *.
                    getStageAD (fst atk.stat_enhance.defense) *.
                    (snd atk.stat_enhance.defense)) +. 2.) in
                atk.current.curr_hp <- atk.current.curr_hp - confuse_damage;
                (false, `Confused))
              ))
      | Leeched::t -> helperVolaStatus t moveDescript'
      | (Substitute _)::t -> helperVolaStatus t moveDescript'
      | Protected::t -> helperVolaStatus t moveDescript'
      | UsedProtect::t -> helperVolaStatus t moveDescript'
      | (ForcedMoveNoSwitch _)::t -> helperVolaStatus t moveDescript'
      | (ForcedMove _)::t -> helperVolaStatus t moveDescript'
      | _ -> failwith "unimplemented" in
  let nvola, vola = atk.current.curr_status in
  match nvola with
  | Freeze -> if List.mem Ice atk.current.pokeinfo.element then (
                atk.current.curr_status <- (NoNon, snd atk.current.curr_status);
                helperVolaStatus vola (`NoFreeze moveDescript))
              else if 20 > Random.int 100 then (
                atk.current.curr_status <- (NoNon, snd atk.current.curr_status);
                helperVolaStatus vola (`Thaw moveDescript))
              else
                (false, `FrozenSolid)
  | Burn -> if List.mem Fire atk.current.pokeinfo.element then (
              atk.current.curr_status <- (NoNon, snd atk.current.curr_status);
              helperVolaStatus vola (`NoBurn moveDescript))
            else
              helperVolaStatus vola (moveDescript)
  | Paralysis -> if List.mem Electric atk.current.pokeinfo.element then (
                atk.current.curr_status <- (NoNon, snd atk.current.curr_status);
                helperVolaStatus vola (`NoPara moveDescript))
                else if 75 > Random.int 100 then (
                  helperVolaStatus vola (moveDescript))
              else
                  (false, `Para)
  | Sleep n -> if n <= 0 then
                (atk.current.curr_status <- (NoNon, snd atk.current.curr_status);
                helperVolaStatus vola (`Wake moveDescript))
               else
                (false ,`Asleep)
  |_ -> helperVolaStatus vola (moveDescript)

(* Helper function for finding protect *)
let rec find_protect lst =
  match lst with
  | Protected::t -> true
  | h::t -> find_protect t
  | [] -> false

(* Returns true if Pokemon moves, otherwise returns false as well as some value
   describing why the move failed *)
let hitAttack atk def (w,t1,t2) (move : move) damage moveDescript =
  let accStage, accMult = atk.stat_enhance.accuracy in
  let evStage, evMult = def.stat_enhance.evasion in
  let probability = float_of_int move.accuracy *. getStageEvasion  accStage
                    *. accMult /. (getStageEvasion evStage *. evMult) in
  let randnum = Random.float 100. in
  let rec need_charge_attack = function
  | (ChargeMove s)::t -> (true, s)
  | (ChargeInSunlight s)::t ->
                (match w with
                | Sun _| HarshSun _-> need_charge_attack t
                | _ -> (true, s))
  | h::t -> need_charge_attack t
  | [] -> (false, "") in
  let rec get_substitute_health = function
  | [] -> None
  | (Substitute n)::_  -> Some n
  | h::t -> get_substitute_health t in
  let hit_move () =
    if probability > randnum || List.mem NeverMiss move.secondary then
      match get_substitute_health (snd def.current.curr_status) with
      | None -> (if find_protect (snd def.current.curr_status) then
                  (false, ProtectedA move.name)
                else
                  (true, moveDescript))
      | Some n -> let sub_damage = max 0 (n - damage) in
                  let newvola = filter_substitute sub_damage (snd def.current.curr_status) in
                  def.current.curr_status <- (fst def.current.curr_status, newvola);
                  if sub_damage = 0 then
                    (false, BreakSub moveDescript)
                  else
                    (false, SubDmg moveDescript)
    else
      (false, MissMove move.name) in
  let need_charge, charge_string = need_charge_attack move.secondary in
  if need_charge then
    if List.mem (Charge) (snd atk.current.curr_status) then
      let volatile_list =
        List.filter (fun s -> not (s = Charge)) (snd atk.current.curr_status) in
      atk.current.curr_status <- (fst atk.current.curr_status, volatile_list);
      hit_move ()
    else
      (atk.current.curr_status <-
        (fst atk.current.curr_status, (ForcedMoveNoSwitch (1, move.name))::(Charge)::(snd atk.current.curr_status));
      (false, ChargingMove (charge_string, move.name)))
  else
    hit_move ()

(* Helper function for finding substitutes *)
let rec find_substitute lst =
  match lst with
  | (Substitute _)::t -> true
  | h::t -> find_substitute t
  | [] -> false
(* Returns true if Pokemon moves, false if it doesn't as well as some value
  describing why it failed (has to do with some status) *)
let hitStatus atk def (move: move) moveDescript =
  match move.target with
  | UserOrAlly | User | UsersField | OpponentsFields
  | Ally | EntireField | UserAndAlly -> (true, moveDescript)
  | _ ->
    let accStage, accMult = atk.stat_enhance.accuracy in
    let evStage, evMult = def.stat_enhance.evasion in
    let probability = float_of_int move.accuracy *. getStageEvasion  accStage
                *. accMult /. (getStageEvasion evStage *. evMult) in
    let randnum = Random.float 100. in
    if probability > randnum then
      if find_substitute (snd def.current.curr_status) then
        (false, SubBlock moveDescript)
      else if find_protect (snd def.current.curr_status) then
        (false, ProtectedS move.name)
      else
        (true, moveDescript)
    else
      (false, MissStatus move.name)

(* Used for writing out the multi move description *)
let rec link_multmove_descript m1 m2 =
  match m2 with
  | HitMult (n, x) ->
      (match m1 with
      | NormMove s -> HitMult (n+1, x)
      | Crit v -> link_multmove_descript v (HitMult(n, Crit x))
      | SEff v -> link_multmove_descript v (HitMult(n, SEff v))
      | NoEff v -> link_multmove_descript v (HitMult (n, NoEff x)))
  | x -> link_multmove_descript m1 (HitMult (1, x))

(* Handles the moves that deal damage *)
let move_handler atk def wt move =
  let weather = match wt with
                | (wt', ter1, ter2) -> (wt'.weather, ter1, ter2) in
  (* Recomputes stats before a move is made -- this happens because a burn
    or some status can occur right before a move is made. *)
  let () = recomputeStat atk in
  let () = recomputeStat def in
  (* Call damage calculation to get preliminary move description and damage
      -- ignores secondary effects *)
  let moveDescript, fdamage = damageCalculation atk def weather move in
  (* creates a reference to move description to allow mutation *)
  let newmove = ref moveDescript in
  (* damage does not need to be mutated *)
  let damage = ref (int_of_float fdamage) in
  (* helper function to deal with secondary effects *)
  let rec secondary_effects lst = match lst with
    (* MultiHit is any move that can occur more than once e.g. Double Slap;
    n is the number of times the move has left to hit *)
    | (MultHit n)::t ->
      (* Once MultHit is done calculating, it calculates rest of effects *)
      if n <= 1 then secondary_effects t else
        (let moveDescript', fdamage' = damageCalculation atk def weather move in
         let damage' = int_of_float fdamage' in
         let newmove' = link_multmove_descript moveDescript' !newmove in
         newmove := newmove';
         def.current.curr_hp <- max 0 (def.current.curr_hp - damage');
         secondary_effects ((MultHit (n-1))::t))
      (* Increase Crit Chance is taken into account during damage dealt -- not
        a real secondary effect so nothing to do here *)
    | (IncCrit _)::t -> secondary_effects t
    (* Calls MultHit after determining how many times to hit consecutively *)
    | RandMultHit::t ->
        let randnum = Random.int 6 + 1 in
        if randnum < 3 then
          secondary_effects ((MultHit 2)::t)
        else if randnum < 5 then
          secondary_effects ((MultHit 3)::t)
        else if randnum < 6 then
          secondary_effects ((MultHit 4)::t)
        else
          secondary_effects ((MultHit 5)::t)
    (* Burns opponent if chance exceeds a certain threshold *)
    | BurnChance::t ->
        let randum = Random.int 100 in
        (if move.effect_chance > randum then
          match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Burn, x);
                           newmove := BurnMove !newmove
          | _ -> ()
        else
          ()); secondary_effects t
    (* Freezes opponent if chance exceeds a certain threshold *)
    | FreezeChance::t ->
        let randnum = Random.int 100 in
        (if move.effect_chance > randnum then
           match def.current.curr_status with
           | (NoNon, x) -> def.current.curr_status <- (Freeze, x);
                            newmove := FreezeMove !newmove
            | _ -> ()
          else
            ()); secondary_effects t
    (* Paralyzed opponent if chance exceeds a certain threshold*)
    | ParaChance::t ->
        let randnum = Random.int 100 in
        (if move.effect_chance > randnum then
          match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Paralysis, x);
                            newmove := ParaMove !newmove
          | _ -> ()
        else
          ()); secondary_effects t
    (* For the move super fang *)
    | SuperFang::t ->
          (let type_mod = List.fold_left (fun acc x -> acc *. getElementEffect
              move.element x) 1. def.current.pokeinfo.element in
            if type_mod > 0. then
              (def.current.curr_hp <- (def.current.curr_hp + !damage)/2;
              secondary_effects t)
            else
              newmove := NoEffAll move.name)
    (* One hit KO moves *)
    | OHKO::t ->
            (let type_mod = List.fold_left (fun acc x -> acc *. getElementEffect
              move.element x) 1. def.current.pokeinfo.element in
            if type_mod > 0. then
              (def.current.curr_hp <- 0; newmove := OHKill !newmove; secondary_effects t)
            else
              newmove := NoEffAll move.name)
    (* Charging Moves dealt with in hit moves-- nothing to do here *)
    | (ChargeMove _)::t | (ChargeInSunlight _)::t -> secondary_effects t
    (* Flinch Moves have a certain chance to make target flinch *)
    | FlinchMove::t ->
        let randnum = Random.int 100 in
        (if move.effect_chance > randnum then
          def.current.curr_status <- (fst def.current.curr_status,
                Flinch::(snd def.current.curr_status))
        else
          ()); secondary_effects t
    (* Recoil moves deal certain damage to the user *)
    | RecoilMove::t ->
        newmove := Recoil !newmove;
        atk.current.curr_hp <- atk.current.curr_hp - !damage / 4
    (* Chance of poisoning the opponent *)
    | PoisonChance::t ->
        let randnum = Random.int 100 in
        (if move.effect_chance > randnum then
          match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Poisoned, x);
                            newmove := PoisonMove !newmove
          | _ -> ()
        else
          ()); secondary_effects t
    (* Constant damage moves -- note these moves have a power level of 0 *)
    | (ConstantDmg n)::t ->
          let type_mod = List.fold_left (fun acc x -> acc *. getElementEffect
            move.element x) 1. def.current.pokeinfo.element in
          if type_mod > 0. then
            (def.current.curr_hp <- max 0 (def.current.curr_hp - n + !damage);
            secondary_effects t)
          else
            newmove := NoEffAll move.name
    (* StageBoost is any status move that boosts stats *)
    | (StageBoost l)::t ->
        (match l with
          | [] -> secondary_effects t
          | (s,n)::t' ->
          let randnum = Random.int 100 in
          if (move.effect_chance > randnum) then
            (match s with
              | Attack ->
                  let stage, multiplier = atk.stat_enhance.attack in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.attack <- (boost, multiplier);
                  newmove := StatBoostA (Attack, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Defense ->
                  let stage, multiplier = atk.stat_enhance.defense in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.defense <- (boost, multiplier);
                  newmove := StatBoostA (Defense, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | SpecialAttack ->
                  let stage, multiplier = atk.stat_enhance.special_attack in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.special_attack <- (boost, multiplier);
                  newmove := StatBoostA
                                    (SpecialAttack, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | SpecialDefense ->
                  let stage, multiplier = atk.stat_enhance.special_defense in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.special_defense <- (boost, multiplier);
                  newmove := StatBoostA
                                    (SpecialDefense, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Speed ->
                  let stage, multiplier = atk.stat_enhance.speed in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.speed <- (boost, multiplier);
                  newmove := StatBoostA (Speed, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Accuracy ->
                  let stage, multiplier = atk.stat_enhance.accuracy in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.accuracy <- (boost, multiplier);
                  newmove := StatBoostA (Accuracy, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Evasion ->
                  let stage, multiplier = atk.stat_enhance.evasion in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.evasion <- (boost, multiplier);
                  newmove := StatBoostA (Evasion, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              ) else secondary_effects ((StageAttack t')::t)
          )
    (* Moves that have a chance of lowering a Pokemon's stat *)
    | (StageAttack l)::t ->
        (match l with
          | [] -> secondary_effects t
          | (s,n)::t' ->
            let randnum = Random.int 100 in
            if (move.effect_chance > randnum) then
            (match s with
              | Attack ->
                  let stage, multiplier = def.stat_enhance.attack in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.attack <- (boost, multiplier);
                  newmove := StatAttackA (Attack, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Defense ->
                  let stage, multiplier = def.stat_enhance.defense in
                  let boost = max (min 6 (stage - n)) (-6) in
                  Printf.printf "%d\n%!" boost;
                  def.stat_enhance.defense <- (boost, multiplier);
                  newmove := StatAttackA (Defense, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | SpecialAttack ->
                  let stage, multiplier = def.stat_enhance.special_attack in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.special_attack <- (boost, multiplier);
                  newmove := StatAttackA
                                    (SpecialAttack, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | SpecialDefense ->
                  let stage, multiplier = def.stat_enhance.special_defense in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.special_defense <- (boost, multiplier);
                  newmove := StatAttackA
                                    (SpecialDefense, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Speed ->
                  let stage, multiplier = def.stat_enhance.speed in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.speed <- (boost, multiplier);
                  newmove := StatAttackA (Speed, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Accuracy ->
                  let stage, multiplier = def.stat_enhance.accuracy in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.accuracy <- (boost, multiplier);
                  newmove := StatAttackA (Accuracy, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Evasion ->
                  let stage, multiplier = def.stat_enhance.evasion in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.evasion <- (boost, multiplier);
                  newmove := StatAttackA (Evasion, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              ) else secondary_effects ((StageAttack t')::t)
          )

    (* Moves that have a chance of confusing the opponent *)
    | ConfuseOpp::t ->let randnum = Random.int 100 in
                          (if (move.effect_chance > randnum) then
                            (let confuse_turns = Random.int 4 + 1 in
                            let novola , x = def.current.curr_status in
                            let rec check_for_confusion = function
                            | [] -> false
                            | (Confusion _)::t -> true
                            | h::t -> check_for_confusion t in
                            (if check_for_confusion x then
                              ()
                            else
                            (def.current.curr_status <-
                              (novola, (Confusion confuse_turns)::x);
                            newmove := ConfuseMoveA !newmove)))
                          else
                           ()); secondary_effects t
    (* Moves that confuse the user *)
    | ConfuseUser::t -> (let confuse_turns = Random.int 4 + 1 in
                            let novola , x = atk.current.curr_status in
                            let rec check_for_confusion = function
                            | [] -> false
                            | (Confusion _)::t -> true
                            | h::t -> check_for_confusion t in
                            (if check_for_confusion x then
                              ()
                            else
                            (atk.current.curr_status <-
                              (novola, (Confusion confuse_turns)::x);
                            newmove := ConfuseUserA !newmove))); secondary_effects t
    (* Moves that take a turn of recharge after use e.g. hyperbeam *)
    | RechargeMove::t -> (atk.current.curr_status <- (fst atk.current.curr_status, RechargingStatus::(snd atk.current.curr_status));
                          newmove := Recharging !newmove; secondary_effects t)
    (* Moves based upon weight are instead based on current health *)
    | WeightDamage::t ->
      (let base_power = def.current.curr_hp * 120 / def.current.bhp in
      move.power <- base_power;
      let moveDescript', fdamage' = damageCalculation atk def weather move in
      let damage' = int_of_float fdamage' in
      def.current.curr_hp <- max 0 (def.current.curr_hp - damage' + !damage));
      secondary_effects t
    (* Damage that varies *)
    | VariableDamage::t ->
      (let base_power = int_of_float ((Random.float 1. +. 0.5) *. 100.) in
        move.power <- base_power;
        let moveDescript', fdamage' = damageCalculation atk def weather move in
        let damage' = int_of_float fdamage' in
        def.current.curr_hp <- max 0 (def.current.curr_hp - damage' + !damage));
        secondary_effects t
    (* for the move flail *)
    | Flail::t ->
        (let base_power = (atk.current.bhp - atk.current.curr_hp) * 200 / atk.current.bhp in
        move.power <- base_power;
        let moveDescript', fdamage' = damageCalculation atk def weather move in
        let damage' = int_of_float fdamage' in
        def.current.curr_hp <- max 0 (def.current.curr_hp - damage' + !damage));
        secondary_effects t
    (* Max health damage *)
    | MaxHealthDmg::t ->
         (let base_power = atk.current.curr_hp * 150 / atk.current.bhp in
        move.power <- base_power;
        let moveDescript', fdamage' = damageCalculation atk def weather move in
        let damage' = int_of_float fdamage' in
        def.current.curr_hp <- max 0 (def.current.curr_hp - damage' + !damage));
        secondary_effects t
    (* Moves that drain health *)
    | DrainMove::t ->
      let heal = !damage / 2 in
      atk.current.curr_hp <- min atk.current.bhp (atk.current.curr_hp + heal);
      newmove := DrainA !newmove
      (* Moves that drain health if opponent is asleep *)
    | DrainMoveSleep::t ->
      (match fst def.current.curr_status with
      | Sleep _ -> secondary_effects (DrainMove::t)
      | _ -> newmove := DrainSleepFail move.name;
            def.current.curr_hp <- def.current.curr_hp + !damage)
            ;secondary_effects t
    (* Moves that cause user to faint *)
    | UserFaint::t -> atk.current.curr_hp <- 0; newmove := UserFaintA !newmove;
                      secondary_effects t
    (* Moves that never miss are handled elsewhere *)
    | NeverMiss::t -> secondary_effects t
    (* Move that leaves the opponent with 1 HP *)
    | FalseSwipe::t -> (if (def.current.curr_hp = 0) then
                          (def.current.curr_hp <- 1;
                          newmove := (FalseSwipeA !newmove))
                       else (); secondary_effects t)
    (* Moves that force a switch out *)
    | ForceSwitch::t -> newmove := SwitchOutA !newmove; secondary_effects t
    (* Base case *)
    | SelfEncore::t ->  let rec findForcedMove = function
                        | (ForcedMoveNoSwitch (n,_))::t ->(true, n)
                        | h::t -> findForcedMove t
                        | [] -> (false,0) in
                        let found, num = findForcedMove (snd atk.current.curr_status) in
                        if found then
                          (if num = 0 then
                            (secondary_effects (ConfuseUser::t))
                          else
                            ())
                        else
                          ( let n = Random.int 2 + 1 in
                            atk.current.curr_status <- (fst atk.current.curr_status, (ForcedMoveNoSwitch (n, move.name))::(snd atk.current.curr_status)))
    | [] -> ()
    in
  let hit, reason = hitMoveDueToStatus atk (`NoAdd !newmove) in
  let rec decompose reason =
    match reason with
    | `NoFreeze s -> NoFreeze (decompose s)
    | `NoBurn s -> NoBurn (decompose s)
    | `NoPara s -> NoPara (decompose s)
    | `Asleep -> Asleep
    | `Wake s -> Wake (decompose s)
    | `Para -> Para
    | `Thaw s -> Thaw (decompose s)
    | `FrozenSolid -> FrozenSolid
    | `Flinch -> FlinchA
    | `NoAdd s -> s
    | `BreakConfuse s -> BreakConfuse (decompose s)
    | `Confused -> Confused in
  let reason' = decompose reason in
  if hit && !damage > 0 then (
    let hit', newreason = hitAttack atk def weather move !damage reason' in
    (* damage is always dealt before secondary effects calculated *)
    if hit' then (
      newmove := newreason;
      damage := min def.current.curr_hp !damage;
      def.current.curr_hp <-def.current.curr_hp - !damage;
      secondary_effects move.secondary;
    (* returns a move description *)
      !newmove)
   else
      newreason)
  else
    reason'

(* Deals with the status moves that are essentially all secondary effects *)
let rec status_move_handler atk def (wt, t1, t2) (move: move) =
  let w = wt.weather in
  (* stats recomputed -- mainly for accuracy/evasion reasons *)
  let () = recomputeStat atk in
  let () = recomputeStat def in
  (* Similar code to move_handler *)
  let newmove = ref (NormStatus move.name) in
  let rec secondary_effects lst = match lst with
    | (StageBoostSunlight l)::t ->
        (match w with
        | HarshSun _ | Sun _ ->
          (secondary_effects
            ((StageBoost (List.map (fun (stat, n) -> (stat, 2 * n)) l))::t))
        | _ -> secondary_effects ((StageBoost l)::t))
  (* StageBoost is any status move that boosts stats *)
    | (StageBoost l)::t ->
        (match l with
          | [] -> secondary_effects t
          | (s,n)::t' ->
            (match s with
              | Attack ->
                  let stage, multiplier = atk.stat_enhance.attack in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.attack <- (boost, multiplier);
                  newmove := StatBoost (Attack, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Defense ->
                  let stage, multiplier = atk.stat_enhance.defense in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.defense <- (boost, multiplier);
                  newmove := StatBoost (Defense, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | SpecialAttack ->
                  let stage, multiplier = atk.stat_enhance.special_attack in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.special_attack <- (boost, multiplier);
                  newmove := StatBoost
                                    (SpecialAttack, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | SpecialDefense ->
                  let stage, multiplier = atk.stat_enhance.special_defense in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.special_defense <- (boost, multiplier);
                  newmove := StatBoost
                                    (SpecialDefense, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Speed ->
                  let stage, multiplier = atk.stat_enhance.speed in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.speed <- (boost, multiplier);
                  newmove := StatBoost (Speed, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Accuracy ->
                  let stage, multiplier = atk.stat_enhance.accuracy in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.accuracy <- (boost, multiplier);
                  newmove := StatBoost (Accuracy, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              | Evasion ->
                  let stage, multiplier = atk.stat_enhance.evasion in
                  let boost = max (min 6 (stage + n)) (-6) in
                  atk.stat_enhance.evasion <- (boost, multiplier);
                  newmove := StatBoost (Evasion, (boost - stage), !newmove);
                  secondary_effects ((StageBoost t')::t)
              )
          )
    (* RandStageBoost randomly boosts a stat *)
    | RandStageBoost::t ->
        (match Random.int 7 with
        | 0 -> secondary_effects (StageBoost[(Attack,2)]::t)
        | 1 -> secondary_effects (StageBoost[(Defense,2)]::t)
        | 2 -> secondary_effects (StageBoost[(SpecialAttack,2)]::t)
        | 3 -> secondary_effects (StageBoost[(SpecialDefense,2)]::t)
        | 4 -> secondary_effects (StageBoost[(Speed,2)]::t)
        | 5 -> secondary_effects (StageBoost[(Accuracy,2)]::t)
        | 6 -> secondary_effects (StageBoost[(Evasion,2)]::t)); secondary_effects t
    (* Move that forces a switch out *)
    | ForceSwitch::t -> newmove := SwitchOut !newmove; secondary_effects t
    (* Move that lowers stat of opponent *)
    | StageAttack l::t ->
        (match l with
          | [] -> secondary_effects t
          | (s,n)::t' ->
            (match s with
              | Attack ->
                  let stage, multiplier = def.stat_enhance.attack in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.attack <- (boost, multiplier);
                  newmove := StatAttack (Attack, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Defense ->
                  let stage, multiplier = def.stat_enhance.defense in
                  let boost = max (min 6 (stage - n)) (-6) in
                  Printf.printf "%d\n%!" boost;
                  def.stat_enhance.defense <- (boost, multiplier);
                  newmove := StatAttack (Defense, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | SpecialAttack ->
                  let stage, multiplier = def.stat_enhance.special_attack in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.special_attack <- (boost, multiplier);
                  newmove := StatAttack
                                    (SpecialAttack, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | SpecialDefense ->
                  let stage, multiplier = def.stat_enhance.special_defense in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.special_defense <- (boost, multiplier);
                  newmove := StatAttack
                                    (SpecialDefense, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Speed ->
                  let stage, multiplier = def.stat_enhance.speed in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.speed <- (boost, multiplier);
                  newmove := StatAttack (Speed, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Accuracy ->
                  let stage, multiplier = def.stat_enhance.accuracy in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.accuracy <- (boost, multiplier);
                  newmove := StatAttack (Accuracy, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              | Evasion ->
                  let stage, multiplier = def.stat_enhance.evasion in
                  let boost = max (min 6 (stage - n)) (-6) in
                  def.stat_enhance.evasion <- (boost, multiplier);
                  newmove := StatAttack (Evasion, (boost - stage), !newmove);
                  secondary_effects ((StageAttack t')::t)
              )
          )
    (* Moves that put opponent to sleep *)
    | PutToSleep::t -> let sleep_turns = Random.int 3 + 2 in
                      (match def.current.curr_status with
                      | (NoNon, x) ->
                         def.current.curr_status <- (Sleep sleep_turns, x);
                        newmove := MakeSleep !newmove
                      | _ -> ()); secondary_effects t
    (* Moves that confuse opponent *)
    | ConfuseOpp::t -> let confuse_turns = Random.int 4 + 1 in
                       let novola , x = def.current.curr_status in
                       let rec check_for_confusion = function
                       | [] -> false
                       | (Confusion _)::t -> true
                       | h::t -> check_for_confusion t in
                       (if check_for_confusion x then
                          ()
                        else
                          (def.current.curr_status <-
                            (novola, (Confusion confuse_turns)::x);
                          newmove := ConfuseMove !newmove)); secondary_effects t
    (* Essentially for Leech Seed *)
    | LeechSeed::t -> let novola, x = def.current.curr_status in
                      let rec check_for_leech = function
                      | [] -> false
                      | Leeched::t -> true
                      | h::t -> check_for_leech t in
                      (if check_for_leech x then
                        ()
                      else
                        (def.current.curr_status <- (novola, Leeched::x);
                        newmove := LeechS !newmove)); secondary_effects t
    (* Burn status moves *)
    | BurnChance::t -> (match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Burn, x);
                            newmove := BurnStatus !newmove
          | _ -> ()); secondary_effects t
    (* Poison status moves *)
    | PoisonChance::t -> (match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Poisoned, x);
                            newmove := PoisonStatus !newmove
          | _ -> ()); secondary_effects t
    (* Paralysis status moves *)
    | ParaChance::t -> (match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Paralysis, x);
                            newmove := ParaStatus !newmove
          | _ -> ()); secondary_effects t
    (* status moves that badly poison opponents *)
    | ToxicChance::t -> (match def.current.curr_status with
          | (NoNon, x) -> def.current.curr_status <- (Toxic 0, x);
                          newmove := BadPoisonStatus !newmove
          | _ -> ()); secondary_effects t
    (* Variable heal depending on weather *)
    | SunHeal::t -> let heal = match w with
                    | ClearSkies -> atk.current.bhp / 2
                    | Sun _| HarshSun _-> 2 * atk.current.bhp / 3
                    | _ -> atk.current.bhp / 4 in
                    atk.current.curr_hp <-
                      min atk.current.bhp (atk.current.curr_hp + heal);
                    newmove := HealHealth !newmove; secondary_effects t
    (* moves that heal the user *)
    | Recovery::t -> let heal = atk.current.bhp / 2 in
                  atk.current.curr_hp <-
                      min atk.current.bhp (atk.current.curr_hp + heal);
                  newmove := HealHealth !newmove; secondary_effects t
    (* moves that make light screen *)
    | LightScreenMake::t -> let rec findLightScreen ter = match ter with
                            | (LightScreen _)::t -> true
                            | h::t -> findLightScreen t
                            | [] -> false in
                            (if findLightScreen !t1 then
                              ()
                            else
                              (t1 := ((LightScreen 4)::!t1);
                              newmove := LightScreenS !newmove));
                            secondary_effects t
    (* move that resets stat boosts/drops *)
    | Haze::t -> atk.stat_enhance <- switchOutStatEnhancements atk;
                 def.stat_enhance <- switchOutStatEnhancements def;
                 newmove := HazeS !newmove;
                 secondary_effects t
    (* for the move Reflect *)
    | ReflectMake::t -> let rec findReflect ter = match ter with
                        | (Reflect _)::t -> true
                        | h::t -> findReflect t
                        | [] -> false in
                        (if findReflect !t1 then
                          ()
                        else
                          (t1 := ((Reflect 4)::!t1);
                          newmove := ReflectS !newmove));
                        secondary_effects t
    (* for the move rest *)
    | Rest::t -> (match atk.current.curr_status with
                  | (Sleep _, _) -> ()
                  | (_, x) -> atk.current.curr_status <- (Sleep 4, x);
                              atk.stat_enhance <- switchOutStatEnhancements atk;
                              atk.current.curr_hp <- atk.current.bhp;
                              newmove := RestS !newmove); secondary_effects t
    (* for the move substitute *)
    | SubstituteMake::t -> (if find_substitute (snd atk.current.curr_status) || atk.current.curr_hp <= atk.current.bhp / 4 then
                        newmove := SubFail !newmove
                      else
                        (atk.current.curr_hp <- atk.current.curr_hp - atk.current.bhp / 4;
                        atk.current.curr_status <- (fst atk.current.curr_status, (Substitute (atk.current.bhp/4))::(snd atk.current.curr_status));
                        newmove := SubMake !newmove)); secondary_effects t
    (* protect has 1/4 chance of working on subsequent use  *)
    | Protect::t -> let rec find = function
                    | [] -> false
                    | UsedProtect::_ -> true
                    | h::t -> find t in
                   (if find (snd atk.current.curr_status) then
                    (if 1 > Random.int 4 then
                      (atk.current.curr_status <- (fst atk.current.curr_status, Protected::(snd atk.current.curr_status));
                      newmove := ProtectS !newmove)
                    else
                      newmove := ProtectFail !newmove)
                  else
                    (atk.current.curr_status <- (fst atk.current.curr_status, Protected::(snd atk.current.curr_status));
                    newmove := ProtectS !newmove)); secondary_effects t
    (* For the move belly drum *)
    | BellyDrum::t -> if atk.current.curr_hp > atk.current.bhp / 2 then
                        (atk.current.curr_hp <- atk.current.curr_hp - atk.current.bhp / 2;
                          secondary_effects ((StageBoost [(Attack,6)])::t))
                      else
                        newmove := Fail "Belly Drum"
    (* for the spikes *)
    | Spikes::t -> let rec addSpikes acc1 acc2 ter = match ter with
                        | (Spikes n)::t ->if n >= 3 then
                                            (false, acc2 @ (Spikes 3)::t)
                                          else
                                            (true, acc2 @ (Spikes (n+1))::t)
                        | h::t -> addSpikes acc1 (h::acc2) t
                        | [] -> (acc1, (Spikes 1)::acc2) in
                  let success, newter = addSpikes true [] !t2 in
                  if success then
                    (t2 := newter;
                    newmove := SpikesS !newmove;
                    secondary_effects t)
                  else
                    newmove := Fail move.name
    (* for heal bell and aromatherapy *)
    | HealBell::t -> let helper_heal poke =
                      poke.curr_status <- (NoNon, snd poke.curr_status) in
                     List.iter helper_heal atk.alive;
                     helper_heal atk.current;
                     newmove := HealBellS !newmove;
                     secondary_effects t
    (* Sunny Day*)
    | SunnyDay::t -> (match w with
                    | Sun _ | HarshSun _ -> ()
                    | _ -> wt.weather <- Sun 5; newmove := SunnyDayS !newmove;
                    secondary_effects t)
    (* Cures burns, paralysis, poison*)
    | Refresh::t -> (match atk.current.curr_status with
                    | (Poisoned, x) -> atk.current.curr_status <- (NoNon, x)
                    | (Toxic _, x) -> atk.current.curr_status <- (NoNon, x)
                    | (Paralysis, x) -> atk.current.curr_status <- (NoNon, x)
                    | (Burn, x) -> atk.current.curr_status <- (NoNon, x)
                    | _ -> ()); newmove := RefreshS !newmove; secondary_effects t
    (* Copies changes to target's stats and replicate to user *)
    | PsychUp::t -> (let i1 = fst def.stat_enhance.attack in
                    let i2 = fst def.stat_enhance.defense in
                    let i3 = fst def.stat_enhance.speed in
                    let i4 = fst def.stat_enhance.special_attack in
                    let i5 = fst def.stat_enhance.special_defense in
                    let i6 = fst def.stat_enhance.evasion in
                    let i7 = fst def.stat_enhance.accuracy in
                    let f1 = snd atk.stat_enhance.attack in
                    let f2 = snd atk.stat_enhance.defense in
                    let f3 = snd atk.stat_enhance.speed in
                    let f4 = snd atk.stat_enhance.special_attack in
                    let f5 = snd atk.stat_enhance.special_defense in
                    let f6 = snd atk.stat_enhance.evasion in
                    let f7 = snd atk.stat_enhance.accuracy in
                    atk.stat_enhance.attack <- (i1,f1);
                    atk.stat_enhance.defense <- (i2,f2);
                    atk.stat_enhance.speed <- (i3,f3);
                    atk.stat_enhance.special_attack <- (i4,f4);
                    atk.stat_enhance.special_defense <- (i5,f5);
                    atk.stat_enhance.evasion <- (i6,f6);
                    atk.stat_enhance.accuracy <- (i7,f7);
                    newmove := PsychUpS !newmove; secondary_effects t)
    (* Flower Shield raises the Defense stat of all Grass-type Pokémon in the battle by one stage. *)
    | FlowerShield::t ->
        ((match ((List.mem Grass atk.current.pokeinfo.element),
              (List.mem Grass def.current.pokeinfo.element)) with
        | (true, true) -> secondary_effects ((StageBoost[(Defense,1)])::(StageAttack[(Defense,-1)])::t)
        | (true, false) -> secondary_effects ((StageBoost[(Defense,1)])::t)
        | (false, true) -> secondary_effects ((StageAttack[(Defense,-1)])::t)
        | _ -> ()); secondary_effects t)
    (* For the move rain dance *)
    | RainDance::t -> ((match w with
                    | Rain _ | HeavyRain _ -> ()
                    | _ -> (wt.weather <- Rain 5; newmove := RainDanceS !newmove));
                    secondary_effects t)
    (* For the move sand storm *)
    | SandStormMake::t -> ((match w with
                    | SandStorm _ -> ()
                    | _ -> (wt.weather <- SandStorm 5; newmove := SandStormS !newmove));
                    secondary_effects t)
    (* For the move hail *)
    | HailMake::t -> ((match w with
                    | Hail _ -> ()
                    | _ -> (wt.weather <- Hail 5; newmove := HailS !newmove));
                    secondary_effects t)
    | (Encore n)::t -> let rec findForcedMove = function
                        | (ForcedMove _)::t -> true
                        | h::t -> findForcedMove t
                        | [] -> false in
                       let containsMove poke str  =
                        poke.pokeinfo.move1.name = str ||
                        poke.pokeinfo.move2.name = str ||
                        poke.pokeinfo.move3.name = str ||
                        poke.pokeinfo.move4.name = str in
                      let prevmove = if wt.terrain.side1 == t1 then !prevmove2 else
                                     if wt.terrain.side1 == t2 then !prevmove1 else
                                      failwith "Faulty Game Logic: Debug 1135" in
                      (if findForcedMove (snd def.current.curr_status) then (newmove := EncoreFail)
                      else if containsMove def.current prevmove then
                        (def.current.curr_status <- (fst def.current.curr_status, (ForcedMove (n, prevmove))::(snd def.current.curr_status));
                        newmove := EncoreS !newmove; secondary_effects t)
                      else
                        (newmove := EncoreFail)
                      )
    | PainSplit::t -> let half_health = (atk.current.curr_hp + def.current.curr_hp)/2 in
                      atk.current.curr_hp <- min atk.current.bhp half_health;
                      def.current.curr_hp <- min def.current.bhp half_health;
                      secondary_effects t
    (* dangerous secondary move with no other additional secondary effects *)
    | CopyPrevMove::[] -> let prevmove = if wt.terrain.side1 == t1 then !prevmove2 else
                         if wt.terrain.side1 == t2 then !prevmove1 else
                         failwith "Faulty Game Logic: Debug 1135" in
                         let validmove = try (let move' = getMoveFromString prevmove in not (List.mem CopyPrevMove move'.secondary)) with _ -> false in
                         if validmove then
                          (let move' = getMoveFromString prevmove in match move'.dmg_class with
                          | Status -> newmove := CopyPrevMoveS (status_move_handler atk def (wt, t1, t2) move')
                          | _ ->  newmove := CopyPrevMoveA (move_handler atk def (wt, t1, t2) move'))
                          else
                            (newmove := CopyFail)
    | [] -> ()
  in
  let hit, reason = hitMoveDueToStatus atk (`NoAdd !newmove) in
  let rec decompose reason =
    match reason with
    | `NoFreeze s -> NoFreezeS (decompose s)
    | `NoBurn s -> NoBurnS (decompose s)
    | `NoPara s -> NoParaS (decompose s)
    | `Asleep -> AsleepS
    | `Wake s -> WakeS (decompose s)
    | `Para -> ParaS
    | `Thaw s -> ThawS (decompose s)
    | `FrozenSolid -> FrozenSolidS
    | `Flinch -> FlinchS
    | `NoAdd s -> s
    | `BreakConfuse s -> BreakConfuseS (decompose s)
    | `Confused -> ConfusedS in
  let reason' = decompose reason in
  if hit then (
    let hit', newreason = hitStatus atk def move reason' in
    if hit' then (
      newmove := newreason;
      (* Returns a description of the status *)
      secondary_effects move.secondary; !newmove)
      (* returns a move description *)
    else
      newreason)
  else
    (atk.current.curr_status <- (fst atk.current.curr_status, List.filter (fun s -> s <> Charge) (snd atk.current.curr_status)); reason')

let rec filterNonvola lst = match lst with
  (* Confusion decremented in hit move due to status *)
  | [] -> []
  | (Confusion n)::t -> (Confusion n)::(filterNonvola t)
  | Flinch::t -> filterNonvola t
  | Leeched::t -> Leeched::filterNonvola t
  (* Charge dealt with in hit attck *)
  | Charge::t -> Charge::(filterNonvola t)
  | (Substitute n)::t-> (Substitute n)::(filterNonvola t)
  | Protected::t -> UsedProtect::(filterNonvola t)
  | UsedProtect::t -> filterNonvola t
  | RechargingStatus::t -> RechargingStatus::(filterNonvola t)
  | (ForcedMove (n, s))::t -> if n = 0 then filterNonvola t else (ForcedMove ((n-1), s))::(filterNonvola t)
  | (ForcedMoveNoSwitch (n, s))::t -> if n <= 0 then filterNonvola t else (ForcedMoveNoSwitch (n-1,s))::(filterNonvola t)

let remove_some_status bp =
  let nonvola, vola = bp.curr_status in
  let newvola = filterNonvola vola in
  match nonvola with
  | Toxic n -> bp.curr_status <- (Toxic (n + 1), newvola)
  | Sleep n -> bp.curr_status <- (Sleep (n - 1), newvola)
  | _ -> bp.curr_status <- (nonvola, newvola)
(* Called after the turn ends; Decrements sleep counter; checks if Pokemon
   faints; etc... Note Pl1 always faints before Pl2*)
let handle_next_turn t1 t2 w m1 m2 =
  (Printf.printf "Turn Ending\n%!";
  match t1.current.curr_hp with
  | 0 -> if (t2.current.curr_hp = 0) then
            (m1 := Pl1 Faint; m2 := Pl2 Faint)
          else
            (m1 := Pl1 Faint; m2 := Pl2 FaintNext)
  | _ -> if (t2.current.curr_hp = 0) then
            (m1 := Pl2 Faint; m2 := Pl1 FaintNext)
          else
            (m1 := Pl1 Next; m2 := Pl2 Next)); remove_some_status t1.current;
  remove_some_status t2.current

(* Handles Preprocessing -- Burn damage, weather damage, healing from Leech
    Seed etc... after every move to prepare for next turn *)
let handle_preprocessing t1 t2 w m1 m2 =
  Printf.printf "Handling preprocessing for move\n%!";
  let rec fix_weather descript = match w.weather with
  | Sun n -> if n <= 0 then
                  (w.weather <- ClearSkies; SunFade descript)
              else
                  (w.weather <- Sun (n-1); descript)
  | Rain n -> if n <= 0 then
                  (w.weather <- ClearSkies; RainFade descript)
              else
                  (w.weather <- Rain (n-1); descript)
  | SandStorm n -> if n <= 0 then
                    (w.weather <- ClearSkies; SandStormFade descript)
                   else
                    (w.weather <- (SandStorm (n-1));
                    match (List.mem Rock t1.current.pokeinfo.element || List.mem Ground t1.current.pokeinfo.element || List.mem Steel t1.current.pokeinfo.element),
                          (List.mem Rock t2.current.pokeinfo.element || List.mem Ground t2.current.pokeinfo.element || List.mem Steel t2.current.pokeinfo.element) with
                    | (false, false) -> (t1.current.curr_hp <- t1.current.curr_hp - t1.current.bhp/16;
                                      t2.current.curr_hp <- t2.current.curr_hp - t2.current.bhp/16;
                                      SandBuffetB descript)
                    | (false, true) -> (t1.current.curr_hp <- t1.current.curr_hp - t1.current.bhp/16;
                                      SandBuffet1 descript)
                    | (true, false) -> (t2.current.curr_hp <- t2.current.curr_hp - t2.current.bhp/16;
                                      SandBuffet2 descript)
                    | (true, true) -> descript)
  | Hail n -> if n <= 0 then
                (w.weather <- ClearSkies; HailFade descript)
              else
                (w.weather <- (Hail (n-1));
                match (List.mem Ice t1.current.pokeinfo.element), (List.mem Ice t2.current.pokeinfo.element) with
                | (false, false) -> (t1.current.curr_hp <- t1.current.curr_hp - t1.current.bhp/16;
                                    t2.current.curr_hp <- t2.current.curr_hp - t2.current.bhp/16;
                                    HailBuffetB descript)
                | (false, true) -> (t1.current.curr_hp <- t1.current.curr_hp - t1.current.bhp/16;
                                    HailBuffet1 descript)
                | (true, false) -> (t2.current.curr_hp <- t2.current.curr_hp - t2.current.bhp/16;
                                    HailBuffet2 descript)
                | (true, true) -> descript )
  | _ -> descript in
  let rec fix_terrain t acc descript =  function
  | (LightScreen n)::t' -> if n = 0 then
                           fix_terrain t acc (LightScreenFade descript) t'
                          else
                            fix_terrain t ((LightScreen (n-1))::acc) descript t'
  | (Reflect n)::t' -> if n = 0 then
                        fix_terrain t acc (ReflectFade descript) t'
                       else
                        fix_terrain t ((Reflect (n-1))::acc) descript t'
  | h::t' -> fix_terrain t (h::acc) descript t'
  | [] -> (acc, descript) in
  let rec fix_vstatus t1 t2 descript1 descript2 = function
  | [] -> (descript1, descript2)
  | Leeched::t ->
        if t2.current.curr_hp > 0 then
          (let damage = t1.current.bhp / 16 in
          t1.current.curr_hp <- t1.current.curr_hp - damage;
          t2.current.curr_hp <- t2.current.curr_hp + damage;
          fix_vstatus t1 t2 (LeechDmg descript1) (LeechHeal descript2) t)
        else
          fix_vstatus t1 t2 descript1 descript2 t
  | h::t -> fix_vstatus t1 t2 descript1 descript2 t in
  let fix_nstatus nstatus t =
  match nstatus with
  | Burn -> if List.mem Fire t.current.pokeinfo.element then
              (t.current.curr_status <- (NoNon, snd t1.current.curr_status);
               BreakBurn)
            else
              (t.current.curr_hp <- t.current.curr_hp - 1 * t.current.bhp / 8;
              BurnDmg)
  | Freeze -> if List.mem Ice t.current.pokeinfo.element then
              (t.current.curr_status <- (NoNon, snd t1.current.curr_status);
              BreakFreeze)
            else
              Base
  | Paralysis -> if List.mem Electric t.current.pokeinfo.element then
                  (t.current.curr_status <- (NoNon, snd t.current.curr_status);
                  BreakPara)
                else
                  Base
  | Poisoned -> if List.mem Poison t.current.pokeinfo.element || List.mem Steel t.current.pokeinfo.element then
                  (t.current.curr_status <- (NoNon, snd t.current.curr_status);
                  BreakPoison)
                else
                  (t.current.curr_hp <- t.current.curr_hp - 1 * t.current.bhp / 8;
                    PoisonDmg)
  | Toxic n -> if List.mem Poison t.current.pokeinfo.element || List.mem Steel t.current.pokeinfo.element then
                  (t.current.curr_status <- (NoNon, snd t.current.curr_status);
                  BreakPoison)
                else
                  (let damage = t.current.bhp * (n+1) / 16 in
                  t.current.curr_hp <- t.current.curr_hp - damage;
                  PoisonDmg)
  | _ -> Base in
  let nstatus, vstatus = t1.current.curr_status in
  let nstatus', vstatus' = t2.current.curr_status in
  let move1 = fix_nstatus nstatus t1 in
  let move2 = fix_nstatus nstatus' t2 in
  let move1', move2' = fix_vstatus t1 t2 move1 move2 vstatus in
  let move2'', move1'' = fix_vstatus t2 t1 move2' move1' vstatus' in
  let (ter1, move1f) = fix_terrain t1 [] move1'' !(w.terrain.side1) in
  let (ter2, move2f) = fix_terrain t2 [] move2'' !(w.terrain.side2) in
  let move2f' = fix_weather move2f in
  (match move1f with
  | Base -> m1 := Pl1 Continue
  | _ -> m1 := Pl1 (EndMove move1f));
  (match move2f' with
  | Base -> m2 := Pl2 Continue
  | _ -> m2 := Pl2 (EndMove move2f'));
  t1.current.curr_hp <- min (max 0 t1.current.curr_hp) t1.current.bhp;
  t2.current.curr_hp <- min (max 0 t2.current.curr_hp) t2.current.bhp;
  w.terrain.side1 := ter1; w.terrain.side2 := ter2

(* Handle the case when both Pokemon use a move *)
let handle_two_moves t1 t2 w m1 m2 a1 a2 =
  let () = recomputeStat t1 in
  let () = recomputeStat t2 in
  let p1poke = t1.current in
  let p2poke = t2.current in
    (* Gets speed of both Pokemon with modifiers *)
  let curr_move = findBattleMove p1poke.pokeinfo a1 in
  let curr_move' = findBattleMove p2poke.pokeinfo a2 in
  let p1speed = ref (float_of_int t1.current.bspeed *.
    getStageAD (fst t1.stat_enhance.speed) *. (snd t1.stat_enhance.speed)) in
  let p2speed = ref (float_of_int t2.current.bspeed *.
    getStageAD (fst t2.stat_enhance.speed) *. (snd t2.stat_enhance.speed)) in
  (if (p1speed = p2speed) && (curr_move.priority = curr_move'.priority) then
      if 50 > Random.int 100 then
        p1speed := 1. +. !p2speed
      else
        ()
  else if (curr_move.priority > curr_move'.priority) then
      p1speed := 1. +. !p2speed
  else if (curr_move'.priority > curr_move.priority) then
      p2speed := 1. +. !p1speed
  else
    ());
  (* Case for where Player 1 is faster *)
  if (!p1speed > !p2speed) || curr_move.priority > curr_move'.priority then (
    (* Gets the moves both pokemon used *)
    prevmove1 := a1;
    match curr_move.dmg_class with
    (* case where Player 1 uses a Status move *)
    | Status -> let newmove = status_move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
            if (List.mem ForceSwitch curr_move.secondary) then
              (m1 := Pl1(Status newmove); m2 := Pl2 NoAction)
            else
              prevmove2 := a2;
              (match curr_move'.dmg_class with
               (* case where Player 2 uses a Status Move *)
              | Status -> let newmove' = status_move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
                  m1 := Pl1 (Status newmove); m2 := Pl2 (Status newmove')
              (* case where Player 2 uses a Special/Physical Move *)
               | _ -> let newmove' = move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
                  m1 := Pl1 (Status newmove); m2 := Pl2 (AttackMove newmove'))
    (* Case where Player 1 uses a Physical/Special Move *)
    | _ -> let newmove = move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
           (* Case where second pokemon faints before getting to move *)
           if (p2poke.curr_hp = 0 || List.mem ForceSwitch curr_move.secondary) then
              (m1 := Pl1 (AttackMove newmove); m2 := Pl2 NoAction)
           (* Case where second pokemon is still alive *)
           else
              prevmove2 := a2;
              (match curr_move'.dmg_class with
              (* Case where Player 2 uses a Status Move *)
              | Status -> let newmove' = status_move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
                          m1 := Pl1 (AttackMove newmove);
                          m2 := Pl2 (Status newmove')
              (* Case where Player 2 Uses a Physical/Special Move *)
              | _      -> let newmove' = move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
                          m1 := Pl1 (AttackMove newmove);
                          m2 := Pl2 (AttackMove newmove')
              )
    )
  (* Case for where Player 2 is faster *)
  else (
    prevmove2 := a2;
    match curr_move'.dmg_class with
    | Status -> let newmove = status_move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
            if (List.mem ForceSwitch curr_move'.secondary) then
             (m1 := Pl2 (Status newmove); m2 := Pl1 NoAction)
            else
            prevmove1 := a1;
            (match curr_move.dmg_class with
            | Status -> let newmove' = status_move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                  m1 := Pl2 (Status newmove); m2 := Pl1 (Status newmove')
            | _ -> let newmove' = move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                  m1 := Pl2 (Status newmove); m2 := Pl1 (AttackMove newmove'))
    | _ -> let newmove = move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move' in
           if (p1poke.curr_hp = 0 || List.mem ForceSwitch curr_move'.secondary) then
              (m1 := Pl2 (AttackMove newmove); m2 := Pl1 NoAction)
           else
              prevmove1 := a1;
              (match curr_move.dmg_class with
              | Status -> let newmove' = status_move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                          m1 := Pl2 (AttackMove newmove);
                          m2 := Pl1 (Status newmove')
              | _      -> let newmove'= move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                          m1 := Pl2 (AttackMove newmove);
                          m2 := Pl1 (AttackMove newmove')
              )
    )

let getEntryHazardDmg t ter1=
  let rec helper acc lst = match lst with
  | [] -> acc
  | (Spikes n)::t -> (if n = 1 then (helper (0.125 +. acc) t)
                      else if n = 2 then (helper (1. /. 6. +. acc) t)
                      else (helper (0.25 +. acc) t))
  | h::t -> helper acc t in
  let damage = int_of_float (helper 0. !ter1 *. float_of_int t.current.bhp) in
  t.current.curr_hp <- max 0 (t.current.curr_hp - damage)

let switchPokeHandler faint nextpoke t ter1 =
  let prevPoke = t.current in
  let switchPoke, restPoke = findBattlePoke t.alive nextpoke in
  t.stat_enhance <- switchOutStatEnhancements t;
  t.current.curr_status <- switchOutStatus t.current;
  t.current <- switchPoke;
  (if faint then
    (t.dead <- prevPoke::t.dead; t.alive <- restPoke)
  else
    t.alive <- prevPoke::restPoke);
  getEntryHazardDmg t ter1

(* test for forced moves *)
let rec getForcedMove lst =
  match lst with
  | (ForcedMove (_, s))::t -> (true, s)
  | h::t -> getForcedMove t
  | [] -> (false, "")

(* The main action handler for the game *)
let handle_action state action1 action2 =
  let t1, t2, w, m1, m2 = match get_game_status state with
    | Battle InGame (t1, t2, w, m1, m2) -> t1, t2, w, m1, m2
    | _ -> failwith "Faulty Game Logic" in
  match action1 with
  | Poke p' -> let p = if p' = "random" then getRandomPoke t1 else p' in
      (match action2 with
      | Poke p2' -> let p2 = if p2' = "random" then getRandomPoke t2 else p2' in
                    switchPokeHandler false p t1 w.terrain.side1;
                    switchPokeHandler false p2 t2 w.terrain.side2;
                    if (t1.current.curr_hp = 0) then
                          if (t2.current.curr_hp = 0) then
                            (m1 := Pl1 SFaint; m2 := Pl2 Faint)
                          else
                            (m1 := Pl1 SFaint; m2 := Pl2 FaintNext)
                        else
                          if (t2.current.curr_hp = 0) then
                            (m1 := Pl2 SFaint; m1 := Pl1 FaintNext)
                          else
                            (m1 := Pl1 (SPoke p); m2 := Pl2 (SPoke p2))
      | UseAttack a2' -> switchPokeHandler false p t1 w.terrain.side1;
                       if (t1.current.curr_hp = 0) then
                        (m1 := Pl1 SFaint; m2 := Pl2 FaintNext)
                      else
                       (let force2, force2s = getForcedMove (snd t2.current.curr_status) in
                        let a2 = if force2 then force2s else a2' in
                        prevmove2 := a2;
                        let curr_move = findBattleMove t2.current.pokeinfo a2 in
                       if curr_move.dmg_class = Status then
                          (let newmove = status_move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move in
                            m1 := Pl1 (SPoke p); m2 := Pl2 (Status newmove))
                       else (
                        let newmove = move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move in
                        m1 := Pl1 (SPoke p); m2 := Pl2 (AttackMove newmove)))
      | NoMove ->  switchPokeHandler false p t1 w.terrain.side1;
                    if (t1.current.curr_hp = 0) then
                      (m1 := Pl1 Faint; m2 := Pl2 FaintNext)
                    else
                       (m1 := Pl1 (SPoke p); m2 := Pl2 NoAction)
      | _ -> failwith "Faulty Game Logic: Debug 444")
  | UseAttack a1' -> let force1, force1s = getForcedMove (snd t1.current.curr_status) in
                     let a1 = if force1 then force1s else a1' in
      (match action2 with
      | Poke p' -> let p  = if p' = "random" then getRandomPoke t2 else p' in
                   switchPokeHandler false p t2 w.terrain.side2;
                    (if (t2.current.curr_hp = 0) then
                      (m1 := Pl2 SFaint; m2 := Pl1 FaintNext)
                    else
                      (let curr_move = findBattleMove t1.current.pokeinfo a1 in
                      prevmove1 := a1;
                      if curr_move.dmg_class = Status then
                        (
                          let newmove = status_move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                        m1 := Pl2 (SPoke p); m1 := Pl1 (Status newmove))
                     else
                      (let newmove = move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                      m1 := Pl2 (SPoke p); m2 := Pl1 (AttackMove newmove))))
      | UseAttack a2' -> let force2, force2s = getForcedMove (snd t2.current.curr_status) in
                          let a2 = if force2 then force2s else a2' in
                          handle_two_moves t1 t2 w m1 m2 a1 a2
      | NoMove -> let curr_poke = t1.current in
                  let curr_move = findBattleMove curr_poke.pokeinfo a1 in
                  prevmove1 := a1;
                  if curr_move.dmg_class = Status then
                    (let newmove = status_move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                    m1 := Pl1 (Status newmove); m2 := Pl2 NoAction)
                  else
                    (let newmove = move_handler t1 t2 (w, w.terrain.side1, w.terrain.side2) curr_move in
                    m1 := Pl1 (AttackMove newmove); m2 := Pl2 NoAction)
      | _ -> failwith "Faulty Game Logic: Debug 449")
  | NoMove -> (match action2 with
              | FaintPoke p ->
                  let prevPoke = t2.current in
                  let switchPoke, restPoke = findBattlePoke t2.alive p in
                  t2.current <- switchPoke; t2.dead <- prevPoke::t2.dead;
                  t2.alive <- restPoke; m1 := Pl2 (SPoke p);
                  m2 := Pl1 Next
              | Poke p' -> let p = if p' = "random" then getRandomPoke t2
                          else p' in
                          switchPokeHandler false p t2 w.terrain.side2;
                          if (t2.current.curr_hp = 0) then
                            (m1 := Pl2 SFaint; m2 := Pl1 FaintNext)
                          else
                            (m1 := Pl2 (SPoke p); m2 := Pl1 NoAction)
              | UseAttack a2' -> let force2, force2s = getForcedMove (snd t2.current.curr_status) in
                              let a2 = if force2 then force2s else a2' in
                              let curr_poke = t2.current in
                              let curr_move = findBattleMove curr_poke.pokeinfo a2 in
                              prevmove2 := a2;
                              if curr_move.dmg_class = Status then
                              ( let newmove = status_move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move in
                                m1 := Pl2 (Status newmove); m2 := Pl1 NoAction)
                              else
                                (let newmove = move_handler t2 t1 (w, w.terrain.side2, w.terrain.side1) curr_move in
                                m1 := Pl2 (AttackMove newmove); m2 := Pl1 NoAction)
              | NoMove -> m1 := Pl1 NoAction; m2 := Pl2 NoAction
              | _ -> failwith "Faulty Game Logic: Debug 177"
              )
  | FaintPoke p -> (match action2 with
                    | FaintPoke p' ->
                        (switchPokeHandler true p t1 w.terrain.side1;
                        switchPokeHandler true p' t2 w.terrain.side2;
                        if (t1.current.curr_hp = 0) then
                          if (t2.current.curr_hp = 0) then
                            (m1 := Pl1 SFaint; m2 := Pl2 Faint)
                          else
                            (m1 := Pl1 SFaint; m2 := Pl2 FaintNext)
                        else
                          if (t2.current.curr_hp = 0) then
                            (m1 := Pl2 SFaint; m1 := Pl1 FaintNext)
                          else
                            m1 := Pl1 (SPoke p); m2 := Pl2 (SPoke p'))
                    | _ ->
                        (switchPokeHandler true p t1 w.terrain.side1;
                        if (t1.current.curr_hp = 0) then
                          (m1 := Pl1 SFaint; m2 := Pl2 FaintNext)
                        else
                          (m1 := Pl1 (SPoke p); m2 := Pl2 Next)))
  | Preprocess -> (match action2 with
                  | Preprocess -> handle_preprocessing t1 t2 w m1 m2
                  | _ -> failwith "Faulty Game Logic: Debug 211")
  | TurnEnd -> (match action2 with
                  | TurnEnd -> handle_next_turn t1 t2 w m1 m2
                  | _ -> failwith "Faulty Game Logic: Debug 276")

(* Main loop for 1 player -- gets input from AI *)
let rec main_loop_1p engine gui_ready ready ready_gui () =
  let t1 = match get_game_status engine with
    | Battle InGame (t1, _, _, _, _) -> t1
    | _ -> failwith "Faulty Game Logic" in
  let t2 = match get_game_status engine with
    | Battle InGame (_, t2, _, _, _) -> t2
    | _ -> failwith "Faulty Game Logic" in
  upon (Ivar.read !gui_ready) (* Replace NoMove with ai move later *)
    (fun (cmd1, cmd2) -> let c1 = unpack cmd1 in
                         let c2 = match (unpack cmd2) with
                          | AIMove -> UseAttack (Ai.getRandomMove t2.current)
                          | NoMove -> NoMove
                          | UseAttack s -> UseAttack s
                          | Preprocess -> Preprocess
                          | Poke s -> Poke s
                          | FaintPoke _ -> FaintPoke (Ai.replaceDead2 t1.current t2.alive)
                          | TurnEnd -> TurnEnd in
                         let () = handle_action engine c1 c2 in
                         gui_ready := Ivar.create ();
                         Ivar.fill !ready_gui true;
                         (main_loop_1p engine gui_ready ready ready_gui ()));
   Printf.printf "Debug %d \n%!" (Scheduler.cycle_count ())

(* Main loop for 2 player -- gets input from two players *)
let rec main_loop_2p engine gui_ready ready ready_gui () =
  upon (Ivar.read !gui_ready)
    (fun (cmd1, cmd2) -> let c1 = unpack cmd1 in let c2 = unpack cmd2 in
                          let () = handle_action engine c1 c2 in
                          gui_ready := Ivar.create ();
                          Ivar.fill !ready_gui true;
                          (main_loop_2p engine gui_ready ready ready_gui ()));
    Printf.printf "Debug %d \n%!" (Scheduler.cycle_count ())

(* Main controller for random one player *)
let rec main_controller_random1p engine gui_ready ready ready_gui=
  let team1 = getRandomTeam () in
  let team2 = getRandomTeam () in
  let battle = initialize_battle team1 team2 in
  let () = engine := Ivar.create (); Ivar.fill !engine battle in
  main_loop_1p engine gui_ready ready ready_gui ()

(* Main controller for random two player *)
let rec main_controller_random2p engine gui_ready ready ready_gui =
  let team1 = getRandomTeam () in
  let team2 = getRandomTeam () in
  let battle = initialize_battle team1 team2 in
  let () = engine := Ivar.create (); Ivar.fill !engine battle in
  main_loop_2p engine gui_ready ready ready_gui ()

let rec main_controller_preset1p engine gui_ready ready ready_gui t =
  let stat_enhance = {attack=(0,1.); defense=(0,1.); speed=(0,1.);
      special_attack=(0,1.); special_defense=(0,1.); evasion=(0,1.);
      accuracy=(0,1.)} in
  let team1' = List.map getBattlePoke t in
  let team1 = {current = List.hd team1'; alive = List.tl team1'; dead = [];
                  stat_enhance} in
  let team2 = getRandomTeam () in
  let battle = initialize_battle team1 team2 in
  let () = engine := Ivar.create (); Ivar.fill !engine battle in
  main_loop_1p engine gui_ready ready ready_gui ()

(* Initialize controller -- called by Game.ml *)
let initialize_controller (engine, battle_engine) =
  let battle_status, gui_ready, ready, ready_gui = battle_engine in
    Printf.printf "Initializing battle\n%!";
  upon (Ivar.read !battle_status) (fun s -> match s with
    | Random1p -> (main_controller_random1p engine gui_ready ready ready_gui)
    | Random2p -> (main_controller_random2p engine gui_ready ready ready_gui)
    | Preset1p t -> (main_controller_preset1p engine gui_ready ready ready_gui t));
  ()