(* Ocsigen
 * http://www.ocsigen.org
 *
 * Copyright (C) 2015
 *      Vincent Balat
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

[%%shared open Eliom_content.Html ]
[%%shared open Eliom_content.Html.F ]

[%%client
class type tabbable = object
  inherit Dom_html.element
  method tabIndex : int Js.prop
end
]

(* makes sense starting with 3 elements (second = next_to_last) *)
let%client setup_tabcycle first second next_to_last last =
  begin Lwt.async @@ fun () -> Lwt_js_events.focuses first @@ fun _ _ ->
    last##.tabIndex := 1;
    first##.tabIndex := 2;
    second##.tabIndex := 3;
    Lwt.return ()
  end;
  begin Lwt.async @@ fun () -> Lwt_js_events.blurs first @@ fun _ _ ->
    first##.tabIndex := 0;
    second##.tabIndex := 0;
    last##.tabIndex := 0;
    Lwt.return ()
  end;
  begin Lwt.async @@ fun () -> Lwt_js_events.focuses last @@ fun _ _ ->
    next_to_last##.tabIndex := 1;
    last##.tabIndex := 2;
    first##.tabIndex := 3;
    Lwt.return ()
  end;
  begin Lwt.async @@ fun () -> Lwt_js_events.blurs last @@ fun _ _ ->
    next_to_last##.tabIndex := 0;
    last##.tabIndex := 0;
    first##.tabIndex := 0;
    Lwt.return ()
  end

(* focussable elements are a real subset of form elements (no buttons) *)
let%client focussable x =
  let do_it elt focus = Some (fun () -> Lwt.async @@ fun () ->
    let%lwt _ = Ot_nodeready.nodeready elt in
    focus ();
    Lwt.return ())
  in
  match Dom_html.tagged x with
  | Dom_html.A        x -> do_it x @@ fun () -> x##focus
  | Dom_html.Input    x -> do_it x @@ fun () -> x##focus
  | Dom_html.Textarea x -> do_it x @@ fun () -> x##focus
  | Dom_html.Select   x -> do_it x @@ fun () -> x##focus
  | _ -> None

let%client try_focus elt = match focussable elt with
  | None -> ()
  | Some focus -> focus ()

let%shared rec list_of_opts = function
  | [] -> []
  | None :: xs -> list_of_opts xs
  | Some x :: xs -> x :: list_of_opts xs

let%client setup_tabcycle elts =
  begin match elts with
  | one :: two :: three :: xs ->
    let last, next_to_last = match List.rev @@ two :: three :: xs with
      | last :: next_to_last :: _ -> last, next_to_last
      | _ -> failwith "Ot_popup.setup_tabcycle: can't happen"
    in
    setup_tabcycle one two next_to_last last
  | _ -> () (* We can't have a proper tab cycle with just two elements *)
         (* TODO: but we can make TAB work (not shift-TAB though)*)
  end;
  (* focus first focussable element *)
  match list_of_opts @@ List.map focussable elts with
  | focus :: _ -> focus ()
  | [] -> ()


let%client coerce_to_tabbable x = let x = Dom_html.element x in
  match Dom_html.tagged x with
  | Dom_html.A        x -> Some (x :> tabbable Js.t)
  (* | Dom_html.Link     x -> Some (x :> tabbable Js.t) *)
  | Dom_html.Button   x -> Some (x :> tabbable Js.t)
  | Dom_html.Input    x -> Some (x :> tabbable Js.t)
  | Dom_html.Select   x -> Some (x :> tabbable Js.t)
  | Dom_html.Textarea x -> Some (x :> tabbable Js.t)
  (* | Dom_html.Menuitem x -> Some (x :> tabbable Js.t) *)
  | _ -> None

let%client tabbable_elts_of elt = list_of_opts @@ List.map coerce_to_tabbable @@
  Dom.list_of_nodeList @@ elt##getElementsByTagName (Js.string "*")

(* TODO: what if there are only one or two form elements? *)
let%client setup_tabcycle_auto form = Lwt.async @@ fun () ->
  Lwt.return @@ setup_tabcycle @@ tabbable_elts_of form

let%shared hcf ?(a=[]) ?(header=[]) ?(footer=[]) content =
  D.section
    ~a:(a_class ["ot-hcf"] :: (a :> Html_types.div_attrib attrib list))
    [ F.header ~a:[ a_class ["ot-hcf-header"] ] header
    ; div ~a:[ a_class ["ot-hcf-content"] ] content
    ; F.footer ~a:[ a_class ["ot-hcf-footer"] ] footer ]

let%client number_of_popups = ref 0

let%client scroll_pos = ref 0

let%client popup
    ?(a = [])
    ?close_button
    ?confirmation_onclose
    ?(onclose = fun () -> Lwt.return ())
    ?(disable_background=true)
    ?(setup_form=false)
    ?(ios_scroll_pos_fix=true)
    gen_content =
  let a = (a :> Html_types.div_attrib attrib list) in
  let gen_content =
    (gen_content :> (unit -> unit Lwt.t) -> Html_types.div_content elt Lwt.t)
  in
  let popup = ref None in

  (let cl = (Js.string "ot-popup") in
   if !number_of_popups <> 0 &&
      (Dom_html.document##getElementsByClassName cl)##.length = 0 then
     (* Before we open a popup, if the number of popups is not 0
        and there's no opened popup, we must reset the popup counter.
        This situation may happen when the user clicks on a link inside
        a popup and loads a new page without resetting the whole environment. *)
     number_of_popups := 0);

  incr number_of_popups;


  let html = Js.Opt.to_option @@
    Js.Opt.map (Dom_html.CoerceTo.html Dom_html.document##.documentElement)
      Of_dom.of_html
  in
  let html_ManipClass_add cl = match html with
    | Some html -> Manip.Class.add html cl
    | None -> ()
  in
  let html_ManipClass_remove cl = match html with
    | Some html -> Manip.Class.remove html cl
    | None -> ()
  in

  if ios_scroll_pos_fix then scroll_pos := Dom_html.document##.body##.scrollTop;
  html_ManipClass_add "ot-with-popup";
  if ios_scroll_pos_fix then Dom_html.document##.body##.scrollTop := !scroll_pos;

  let background_tabIndices = ref None in
  let maybe_restore_tabIndices () = match !background_tabIndices with
    | None -> ()
    | Some indices ->
      ignore @@ List.map (fun (elt, i) -> elt##.tabIndex := i) indices
  in

  let do_close () =
    decr number_of_popups;
    if !number_of_popups = 0 then begin
      html_ManipClass_remove "ot-with-popup";
      if ios_scroll_pos_fix then
        Dom_html.document##.body##.scrollTop := !scroll_pos
    end;
    let () = Eliom_lib.Option.iter Manip.removeSelf !popup in
    maybe_restore_tabIndices ();
    onclose ()
  in

  begin Eliom_client.onunload @@ fun () ->
    html_ManipClass_remove "ot-with-popup";
    None
  end;

  let close () =
    match confirmation_onclose with
    | None -> do_close ()
    | Some f ->
      match%lwt f ()
      with true -> do_close ()
         | false -> Lwt.return ()
  in
  (* FIXME: use a list for gen_content return type *)
  let%lwt c = Ot_spinner.with_spinner ~a:[a_class ["ot-popup-content"]]
      (Lwt.map (fun x -> [x]) (gen_content do_close))
  in

  if disable_background || setup_form then begin
    let form_container = match Dom.list_of_nodeList @@
             (To_dom.of_element c)##getElementsByTagName (Js.string "form") with
    | [form] -> form
    | _ -> (To_dom.of_element c :> Dom.element Js.t)
    in

    if setup_form then begin Ot_spinner.when_loaded @@ fun () ->
      setup_tabcycle @@ tabbable_elts_of form_container
    end;

    if disable_background then begin
      let all_tabbable_elts = tabbable_elts_of Dom_html.document in
      let not_in_form elt = not @@ Ot_lib.in_ancestors
          ~elt:(elt :> Dom_html.element Js.t)
          ~ancestor:(Dom_html.element form_container) in
      let background_elts = List.filter not_in_form all_tabbable_elts in
      let save_tabindex_and_disable_elt elt =
        let old_tabIndex = elt##.tabIndex in
        elt##.tabIndex := -1;
        (* Dom_html.document##.body##.tabIndex := -1; *)
        (elt, old_tabIndex)
      in
      background_tabIndices := Some
          (List.map save_tabindex_and_disable_elt background_elts)
    end
  end;

  let content = [c] in
  let content = match close_button with
    | Some but ->
        Form.button_no_value ~button_type:`Button
          ~a:[ a_class ["ot-popup-close"]
             ; a_onclick (fun ev -> Lwt.async (fun () -> close ())) ] but
        :: content
    | None -> content in
  let pop = D.div ~a:[a_class ["ot-popup"]] content in
  let box = D.div ~a:(a_class ["ot-popup-background"] :: a) [ pop ] in
  popup := Some box;
  Manip.appendToBody box;
  (* We must set the height explicitely, otherwise it does not
     resize correctly when there is an hcf inside. *)
  (* (To_dom.of_element pop)##style##height <- Js.string "999999px"; *)
  (* lwt () = Lwt_js_events.request_animation_frame () in *)
  (* (To_dom.of_element pop)##style##height <- *)
  (*   Js.string (Printf.sprintf "%dpx" (To_dom.of_element c)##offsetHeight) ; *)
  Lwt.return box

let%client ask_question ?a ?a_hcf ~header ~buttons contents =
  let t, w = Lwt.wait () in
  let%lwt _ =
    popup ?a
      (fun do_close ->
         let answers =
           List.map (fun (content, action, btn_class) ->
             let btn = D.Raw.button ~a:[ a_class btn_class ] content in
             (* Onlick, give t the selected value
                and close question popup. *)
             Lwt.async (fun () ->
               Lwt_js_events.clicks (To_dom.of_element btn)
                 (fun _ _ ->
                    let%lwt r = action () in
                    let%lwt result = do_close () in
                    Lwt.wakeup w r;
                    Lwt.return result
                    ) )
           ; btn ) buttons in
         Lwt.return ( hcf ?a:a_hcf ~header ~footer:answers contents ) )
  in t

let%client confirm ?(a = []) question yes no =
  let a = (a :> Html_types.div_attrib attrib list) in
  ask_question
    ~a:(a_class [ "ot-popup-confirmation" ] :: a)
    ~header:question
    ~buttons:[ (yes, (fun () -> Lwt.return true) , ["ot-popup-yes"])
             ; (no , (fun () -> Lwt.return false), ["ot-popup-no"]) ] []

