open Owl
module N = Dense.Ndarray.S
module C = Configuration

(* Recommended preprocessing for ResNet. *)
let add_rgb img rgb =
  let img = N.copy img in
  let r = N.get_slice [[];[];[0]] img in
  let g = N.get_slice [[];[];[1]] img in
  let b = N.get_slice [[];[];[2]] img in

  N.add_scalar_ r rgb.(0);
  N.add_scalar_ g rgb.(1);
  N.add_scalar_ b rgb.(2);

  N.set_slice [[];[];[0]] img r;
  N.set_slice [[];[];[1]] img g;
  N.set_slice [[];[];[2]] img b;
  img

let preprocess img =
  add_rgb img (Array.map (~-.) C.mean_pixel)

let convert_back img =
  add_rgb img C.mean_pixel

let save dest format img =
  Images.save dest (Some format) [] img

(* Converts an Ndarray to a Camlimages' Image. *)
let img_of_ndarray arr =
  let shape = N.shape arr in
  assert ((Array.length shape) = 3 && shape.(2) = 3);
  let img = Rgb24.create shape.(1) shape.(0) in
  for i = 0 to shape.(0) - 1 do
    for j = 0 to shape.(1) - 1 do
      Rgb24.set img j i {r = int_of_float (N.get arr [|i;j;0|]);
                         g = int_of_float (N.get arr [|i;j;1|]);
                         b = int_of_float (N.get arr [|i;j;2|])}
    done;
  done;
  Images.Rgb24 img

let camlimg_to_ndarray img =
  let w, h = Images.size img in
  let img_rgb = match img with
    | Rgb24 x -> x
    | _ -> invalid_arg "unsupported image format" in (* TODO *)
  let res = N.empty [|h; w; 3|] in
  for i = 0 to h - 1 do
    for j = 0 to w - 1 do
      let color = Rgb24.get img_rgb j i in
      N.set res [|i;j;0|] (float color.r);
      N.set res [|i;j;1|] (float color.g);
      N.set res [|i;j;2|] (float color.b);
    done;
  done;
  res

let img_to_ndarray src =
  let img = Images.load src [] in
  camlimg_to_ndarray img

(* Converts the file src to an Ndarray of colors RGB. Keeps the original scale
 * and pads with 0's if necessary. *)
let resize ?w ?h src =
  let img = Images.load src [] in (* load parameters? *)
  let img_w, img_h = Images.size img in
  let w = match w with | Some w -> w | None -> img_w in
  let h = match h with | Some h -> h | None -> img_h in

  let scale =
    let scale_w = float w /. float img_w
    and scale_h = float h /. float img_h in
    min scale_w scale_h in
  let window_w = int_of_float (Owl.Maths.round (scale *. (float img_w)))
  and window_h = int_of_float (Owl.Maths.round (scale *. (float img_h))) in
  let img = match img with
    | Rgb24 map -> Rgb24.resize None map window_w window_h
    | _ -> invalid_arg "not implemented yet" in (* TODO *)
  let img_arr = camlimg_to_ndarray (Rgb24 img) in
  let top_pad, left_pad = (h - window_h) / 2, (w - window_w) / 2 in
  let bottom_pad, right_pad = h - window_h - top_pad, w - window_w - left_pad in
  let padding = [[top_pad; bottom_pad]; [left_pad; right_pad]; [0; 0]] in
  let window = [|top_pad; left_pad; window_h + top_pad; window_w + left_pad|] in
  let image = N.pad ~v:0. padding img_arr in
  image, [|img_h; img_w; 3|], window, scale, padding

type image_meta =
  { image_id             : int;
    original_image_shape : int array;
    image_shape          : int array;
    window               : int array;
    scale                : float;
    active_class_ids     : int array;
  }

(* Assumes batch_size of 1. *)
let parse_image_meta meta =
  let open N in
  { image_id             = int_of_float (meta.%{[|0;0|]});
    original_image_shape = Array.map int_of_float
                             (to_array (get_slice [[0];[1;3]] meta));
    image_shape          = Array.map int_of_float
                             (to_array (get_slice [[0];[4;6]] meta));
    window               = Array.map int_of_float
                             (to_array (get_slice [[0];[7;10]] meta));
    scale                = meta.%{[|0;11|]};
    active_class_ids     = Array.map int_of_float
                             (to_array (N.get_slice [[0];[12;-1]] meta));
  }

let compose_image_meta image_id original_shape image_shape window scale =
  let meta = N.zeros [|C.image_meta_size|] in
  let set a b array = N.set_slice [[a; b]] meta
                        (N.of_array array [|Array.length array|]) in
  set 0 0 [|float image_id|];
  set 1 3 (Array.map float original_shape);
  set 4 6 (Array.map float image_shape);
  set 7 10 (Array.map float window);
  set 11 11 [|scale|];
  (* from 12 to last: all class ids are used *)
  meta

let mold_inputs src =
  let h, w = C.image_shape.(0), C.image_shape.(1) in
  let molded_image, original_shape, window, scale, _ = resize ~w ~h src in
  let processed_image = preprocess molded_image in
  let image_meta = compose_image_meta 0 original_shape
                     (N.shape processed_image) window scale in
  processed_image, image_meta, window



(* Applies the deltas to the boxes.
 * Boxes: [N, [y1, x1, y2, x2]], deltas: [N, [dx, dy, log(dh), log(dy)]]. *)
let apply_box_deltas boxes deltas =
  let open N in
  (* Convert to [y, x, h, w] *)
  let height = get_slice [[]; [2]] boxes - get_slice [[]; [0]] boxes in
  let width = get_slice [[]; [3]] boxes - get_slice [[]; [1]] boxes in
  let center_y = get_slice [[]; [0]] boxes + (height *$ 0.5) in
  let center_x = get_slice [[]; [1]] boxes + (width *$ 0.5) in
  (* Apply deltas *)
  mul_ ~out:height height (exp (get_slice [[]; [2]] deltas));
  mul_ ~out:width width (exp (get_slice [[]; [3]] deltas));
  add_ ~out:center_y center_y ((get_slice [[]; [0]] deltas) * height);
  add_ ~out:center_x center_x ((get_slice [[]; [1]] deltas) * width);
  (* Convert back *)
  mul_scalar_ height 0.5;
  mul_scalar_ width 0.5;
  let y1 = center_y - height
  and x1 = center_x - width in
  add_ ~out:center_y center_y height; (* y2 *)
  add_ ~out:center_x center_x width; (* x2 *)
  let result = concatenate ~axis:1 [|y1; x1; center_y; center_x|] in
  result

(* Clip boxes to image boundaries.
 * Boxes: [N, [y1, x1, y2, x2]], window: [y1, x1, y2, x2]. *)
let clip_boxes boxes window =
  let open N in
  let edges = split [|1; 1; 1; 1|] window in
  let cols = split ~axis:1 [|1; 1; 1; 1|] boxes in
  (* relies on the broadcast operation *)
  min2_ cols.(0) edges.(2); max2_ cols.(0) edges.(0);
  min2_ cols.(1) edges.(3); max2_ cols.(1) edges.(1);
  min2_ cols.(2) edges.(2); max2_ cols.(2) edges.(0);
  min2_ cols.(3) edges.(3); max2_ cols.(3) edges.(1);
  concatenate ~axis:1 cols

let _shift = N.of_array [|0.; 0.; 1.; 1.|] [|4|]

(* this should be changed if batch size > 1 *)
let norm_boxes boxes shape =
  let h, w = float shape.(0), float shape.(1) in
  let scale = N.of_array [|h; w; h; w|] [|4|] in N.sub_scalar_ scale 1.;
  N.((boxes - _shift) / scale)

let denorm_boxes boxes shape =
  let h, w = float shape.(0), float shape.(1) in
  let scale = N.of_array [|h; w; h; w|] [|4|] in N.sub_scalar_ scale 1.;
  N.(round ((boxes * scale) + _shift))

let area box = (box.(2) -. box.(0)) *. (box.(3) -. box.(1))

(* Check that the point (y1, x1) is always the top left corner? *)
let intersection_over_union box1 box2 =
  let y1 = max box1.(0) box2.(0)
  and x1 = max box1.(1) box2.(1)
  and y2 = min box1.(2) box2.(2)
  and x2 = min box1.(3) box2.(3) in
  let area1, area2 = area box1, area box2 in
  let inter_area = max 0. (y2 -. y1) *. max 0. (x2 -. x1) in
  inter_area /. (area1 +. area2 -. inter_area +. 1e-6)

(* Greedily returns the indices of the boxes with the highest score that don't
 * have an intersection over union greater than iou_threshold with each
 * other. Takes at most max_output_size boxes.
 * TODO is it possible to use vectorised ops to speed up the computation? *)
let non_max_suppression boxes scores max_output_size iou_threshold =
  let n = (N.shape boxes).(0) in
  assert (n = (N.shape scores).(0));
  let scores_i = Array.init n (fun i -> (N.get scores [|i|], i)) in
  (* Sorts the indices in decreasing order of score *)
  Array.sort (fun a b -> - MrcnnUtil.comp2 a b) scores_i;
  let ixs = Array.init n (fun i -> snd scores_i.(i)) in
  let boxes = Array.init n (fun i ->
                  Array.init 4 (fun j -> N.get boxes [|ixs.(i); j|])) in
  let selected = Array.make n (-1)
  and size = ref 0
  and i = ref 0 in
  while !i < n && !size < max_output_size do
    let ok = ref true
    and j = ref (!size - 1) in
    while !ok && !j >= 0 do
      if intersection_over_union boxes.(!i) boxes.(selected.(!j)) > iou_threshold then
        ok := false;
      j := !j - 1;
    done;
    if !ok then (
      selected.(!size) <- !i;
      size := !size + 1;
    );
    i := !i + 1;
  done;
  Array.map (fun i -> ixs.(i)) (Array.sub selected 0 !size)

let crop_and_resize_box ?out ?(extrapolation_value=0.) image box shape =
  let y1, x1, y2, x2 = box.(0), box.(1), box.(2), box.(3) in
  let img_h, img_w, dep = let sh = (N.shape image) in sh.(0), sh.(1), sh.(2) in
  let img_hf, img_wf = float img_h, float img_w in
  let crop_h, crop_w = shape.(0), shape.(1) in
  let crop_hf, crop_wf = float crop_h, float crop_w in
  let h_scale = if crop_h > 1 then (y2 -. y1) *. (img_hf -. 1.) /. (crop_hf -. 1.)
                else 0. in
  let w_scale = if crop_w > 1 then (x2 -. x1) *. (img_wf -. 1.) /. (crop_wf -. 1.)
                else 0. in
  let result = match out with
    | Some out -> out
    | None -> N.empty [|crop_h; crop_w; dep|]
  in
  let set_res y x d v = N.set result [|y; x; d|] v in

  for y = 0 to crop_h - 1 do
    let yf = float y in
    let in_y = if crop_h > 1 then y1 *. (img_hf -. 1.) +. yf *. h_scale
               else 0.5 *. (y1 +. y2) *. (img_hf -. 1.) in
    if in_y < 0. || in_y > img_hf -. 1. then
      for x = 0 to crop_w - 1 do
        for d = 0 to dep - 1 do
          set_res y x d extrapolation_value;
        done;
      done
    else
      (* linear interpolation *)
      let top_y = int_of_float (floor in_y)
      and bottom_y = int_of_float (ceil in_y) in
      let y_lerp = in_y -. (floor in_y) in
      for x = 0 to crop_w - 1 do
        let xf = float x in
        let in_x = if crop_w > 1 then x1 *. (img_wf -. 1.) +. xf *. w_scale
                   else 0.5 *. (x1 +. x2) *. (img_wf -. 1.) in
        if in_x < 0. || in_x > img_wf -. 1. then
          for d = 0 to dep - 1 do
            set_res y x d extrapolation_value;
          done
        else
          let left_x = int_of_float (floor in_x)
          and right_x = int_of_float (ceil in_x) in
          let x_lerp = in_x -. (floor in_x) in
          for d = 0 to dep - 1 do
            let top_left = N.get image [|top_y; left_x; d|] in
            let top_right = N.get image [|top_y; right_x; d|] in
            let bottom_left = N.get image [|bottom_y; left_x; d|] in
            let bottom_right = N.get image [|bottom_y; right_x; d|] in
            let top = top_left +. (top_right -. top_left) *. x_lerp in
            let bottom = bottom_left +. (bottom_right -. bottom_left) *. x_lerp in
            set_res y x d (top +. (bottom -. top) *. y_lerp);
          done
      done
  done;
  result

(* For each box in boxes, crops the box out of the image and resize it to
 * crop_shape using bilinear interpolation.
 * The boxes should be in normalised coordinates.
 * Returns a tensor of shape [num_boxes, crop_shape.(0), crop_shape.(1),
 * depth].
 * Algorithm ported from https://github.com/tensorflow/tensorflow/blob/
 * master/tensorflow/core/kernels/crop_and_resize_op.cc#L202 *)
let crop_and_resize image boxes crop_shape =
  let n, d = (N.shape boxes).(0), (N.shape image).(2) in
  let results = N.empty Array.(append (append [|n|] crop_shape) [|d|]) in
  for i = 0 to n - 1 do
    let box = Array.init 4 (fun j -> N.get boxes [|i; j|]) in
    let out = N.squeeze ~axis:[|0|] (N.sub_left results i 1) in
    crop_and_resize_box ~out image box crop_shape |> ignore
  done;
  results


let compute_backbone_shapes image_shape strides =
  Array.init 5 (fun i ->
      Array.init 2 (fun j -> ceil ((float image_shape.(j)) /. strides.(i))))

let generate_anchors scale ratios img_shape feature_stride anchor_stride =
  let ratios = N.of_array ratios [|Array.length ratios|] in
  let n = (N.shape ratios).(0) in
  let scale_arr = N.create (N.shape ratios) scale in
  let heights = N.((scale_arr / sqrt ratios) /$ 2.) in
  let widths = N.((scale_arr * sqrt ratios) /$ 2.) in

  let shifts_y, shifts_x =
    let nb_elts upper = (int_of_float ((upper -. 1.) /. anchor_stride)) + 1 in
    let build_shift s = N.sequential ~a:0. ~step:anchor_stride [|nb_elts s|] in
    N.(build_shift img_shape.(0) *$ feature_stride),
    N.(build_shift img_shape.(1) *$ feature_stride) in

  let ny = (N.shape shifts_y).(0)
  and nx = (N.shape shifts_x).(0) in
  let decomp x = ((x / (nx * n)) mod ny, (x / n) mod nx, x mod n) in
  let y1 = N.init [|ny * nx * n; 1|]
             (fun x -> let (i, _, k) = decomp x in
                       N.get shifts_y [|i|] -. N.get heights [|k|]) in
  let x1 = N.init [|ny * nx * n; 1|]
             (fun x -> let (_, j, k) = decomp x in
                       N.get shifts_x [|j|] -. N.get widths [|k|]) in
  let y2 = N.init [|ny * nx * n; 1|]
             (fun x -> let (i, _, k) = decomp x in
                       N.get shifts_y [|i|] +. N.get heights [|k|]) in
  let x2 = N.init [|ny * nx * n; 1|]
             (fun x -> let (_, j, k) = decomp x in
                       N.get shifts_x [|j|] +. N.get widths [|k|]) in
  let anchors = N.concatenate ~axis:1 [|y1; x1; y2; x2|] in
  anchors

let generate_pyramid_anchors scales ratios feature_shapes feature_strides
      anchor_stride =
  let anchors = Array.init (Array.length scales)
                  (fun i -> generate_anchors scales.(i) ratios feature_shapes.(i)
                              feature_strides.(i) anchor_stride) in
  N.concatenate ~axis:0 anchors

let get_anchors image_shape =
  let strides = Array.map float C.backbone_strides in
  let backbone_shapes = compute_backbone_shapes image_shape strides in
  let anchors = generate_pyramid_anchors C.rpn_anchor_scales C.rpn_anchor_ratios
                  backbone_shapes strides (float C.rpn_anchor_stride) in
  norm_boxes anchors image_shape

let unmold_mask mask box =
  let threshold = 0.5 in
  let y1, x1, y2, x2 =
    let box_i i = int_of_float N.(box.%{[|i|]}) in
    box_i 0, box_i 1, box_i 2, box_i 3 in
  let mask =
    let tmp = crop_and_resize_box (N.expand ~hi:true mask 3)
                [|0.; 0.; 1.; 1.|] [|y2 - y1; x2 - x1|] in
    let tmp2 = N.squeeze ~axis:[|2|] tmp in
    N.map (fun elt -> if elt >= threshold then 1. else 0.) tmp2 in
  mask, y1, x1, y2, x2

(* Reformats the results of the neural network in a more suitable format.
 * detections: [N, [y1, x1, y2, x2, class_id, score]]
 * mrcnn_mask: [N, height, width, num_classes]
 * original_image_shape: [H, W, C]
 * image_shape: [H, W, C]
 * window: [y1, x1, y2, x2] *)
let unmold_detections detections mrcnn_mask original_image_shape image_shape
      window =
  (* Finds number of detections (detections is padded with zero but when valid,
   * class_id should be >= 1. Should be called on a single batch slice. *)
  let len = (N.shape detections).(0) in
  let n = let rec loop i =
            if i >= len then len
            else if N.get detections [|i; 4|] = 0. then i
            else loop (i + 1) in
          loop 0 in

  let boxes = N.get_slice [[0;n-1];[0;3]] detections in
  let window = norm_boxes
                 (N.of_array (Array.map float window) [|4|]) image_shape in
  let wy1, wx1, wy2, wx2 =
    N.(window.%{[|0|]}, window.%{[|1|]}, window.%{[|2|]}, window.%{[|3|]}) in
  let shift = N.of_array [|wy1; wx1; wy1; wx1|] [|4|] in
  let wh = wy2 -. wy1
  and ww = wx2 -. wx1 in
  let scale = N.of_array [|wh; ww; wh; ww|] [|4|] in
  let boxes =
    let tmp_boxes = N.((boxes - shift) / scale) in
    denorm_boxes tmp_boxes original_image_shape in

  (* Keep only boxes with area > 0 *)
  let keep = MrcnnUtil.select_indices n (fun i ->
                 N.((boxes.%{[|i;2|]} -. boxes.%{[|i;0|]}) *.
                      (boxes.%{[|i;3|]} -. boxes.%{[|i;1|]})) > 0.) in
  let n = Array.length keep in
  let boxes = MrcnnUtil.gather_slice ~axis:0 boxes keep in
  (* Extracts boxes, class_ids, scores and masks *)
  let class_ids = Array.init n (fun i ->
                      int_of_float (N.get detections [|keep.(i); 4|])) in
  let masks =
    let mask_h, mask_w = let sh = N.shape mrcnn_mask in sh.(1), sh.(2) in
    MrcnnUtil.init_slice ~axis:0 [|n; mask_h; mask_w|]
      (fun i -> N.get_slice [[keep.(i)];[];[];[class_ids.(i)]] mrcnn_mask
                |> N.squeeze ~axis:[|3|]) in
  let scores = MrcnnUtil.gather_slice ~axis:0
                 (N.get_slice [[];[5]] detections) keep
               |> N.squeeze ~axis:[|1|] in

  let full_masks =
    let f =
      (fun i ->
        let tmp = N.get_slice [[i];[];[]] masks |> N.squeeze ~axis:[|0|] in
        let box = N.get_slice [[i];[]] boxes |> N.squeeze ~axis:[|0|] in
        unmold_mask tmp box) in
    f
    in

  boxes, class_ids, scores, full_masks
