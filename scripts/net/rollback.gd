class_name Rollback
extends RefCounted
## GGPO-style rollback over GameSim.save_state/load_state. Transport-agnostic:
## call tick() once per 60 Hz frame with the local input, feed every packet
## from the other player to on_packet(), and send make_packet() each frame.
##
## The local input is scheduled DELAY frames ahead, which hides small pings
## entirely. Missing remote inputs are predicted (the last known input is
## repeated). When the real input arrives and differs, the sim rewinds to that
## frame and re-runs up to the present. We never run more than MAX_RB frames
## ahead of the last confirmed remote input; past that the game waits.

const DELAY := 2
const MAX_RB := 10
const SEND_MAX := 32
const HASH_EVERY := 30

var sim: GameSim
var me := 0               # 0 = host (P1), 1 = joiner (P2)
var frame := 0            # next frame to simulate
var local_in := {}        # frame -> local bits
var remote_in := {}       # frame -> confirmed remote bits
var remote_last := DELAY - 1   # every remote input up to here is known
var remote_ack := DELAY - 1    # the remote has every local input up to here
var remote_frame := 0     # the remote's own frame counter (last reported)
var remote_adv := 0       # the remote's frame advantage, as it reported it
var used := {}            # frame -> remote bits the sim actually used
var snaps := {}           # frame -> state before simulating that frame
var rollback_from := -1
var my_hashes := {}       # frame -> state hash (confirmed frames only)
var remote_hashes := {}
var last_hash_frame := -1
var desync_frame := -1
var skip_cool := 0
# Stats for the HUD
var rollbacks := 0
var rb_frames := 0
var stalls := 0

func _init(s: GameSim, my_slot: int) -> void:
	sim = s
	me = my_slot
	for f in DELAY:
		local_in[f] = 0
		remote_in[f] = 0

## Advances at most one frame. Returns the sim events of the new frame (to
## turn into effects), or null when the game is waiting on the other player.
func tick(local_bits: int):
	_apply_rollback()
	_check_hashes()
	if frame - remote_last > MAX_RB:
		stalls += 1
		return null
	# Time sync: when we are clearly ahead of the other player, wait a frame
	# now and then so both clocks line up and rollbacks stay short.
	if skip_cool > 0:
		skip_cool -= 1
	var adv := frame - remote_frame
	if skip_cool == 0 and (adv - remote_adv) / 2 >= 1 and frame > 60:
		skip_cool = 8
		stalls += 1
		return null
	local_in[frame + DELAY] = local_bits
	var evs := _sim_frame(frame)
	frame += 1
	_trim()
	return evs

func _remote_for(f: int) -> int:
	if remote_in.has(f):
		return remote_in[f]
	return remote_in.get(remote_last, 0)

func _sim_frame(f: int) -> Array:
	snaps[f] = sim.save_state()
	var r := _remote_for(f)
	used[f] = r
	var l: int = local_in.get(f, 0)
	sim.step([l, r] if me == 0 else [r, l])
	return sim.events.duplicate()

func _apply_rollback() -> void:
	if rollback_from < 0 or rollback_from >= frame:
		rollback_from = -1
		return
	var start := rollback_from
	rollback_from = -1
	rollbacks += 1
	rb_frames += frame - start
	sim.load_state(snaps[start])
	for f in range(start, frame):
		_sim_frame(f)

func _check_hashes() -> void:
	# A frame's starting state is final once every input before it is known.
	var f := (mini(remote_last + 1, frame) / HASH_EVERY) * HASH_EVERY
	if f > last_hash_frame and f > 0 and (f == frame or snaps.has(f)):
		last_hash_frame = f
		var s: Dictionary = snaps[f] if f < frame else sim.st
		my_hashes[f] = var_to_str(s).hash()
		if OS.has_environment("UBF_DUMP"):
			var fa := FileAccess.open("%s_%d_%d.txt" % [OS.get_environment("UBF_DUMP"), me, f], FileAccess.WRITE)
			fa.store_string(var_to_str(s))
	for hf in remote_hashes.keys():
		if my_hashes.has(hf):
			if my_hashes[hf] != remote_hashes[hf] and desync_frame < 0:
				desync_frame = hf
				push_warning("Rollback desync at frame %d" % hf)
			remote_hashes.erase(hf)

func _trim() -> void:
	var keep := mini(frame - MAX_RB - 2, remote_last - 2)
	for d in [snaps, used]:
		for k in d.keys():
			if k < keep:
				d.erase(k)
	for k in local_in.keys():
		if k < remote_ack - 2 and k < keep:
			local_in.erase(k)
	for k in remote_in.keys():
		if k < keep and k < remote_last:
			remote_in.erase(k)
	for k in my_hashes.keys():
		if k < last_hash_frame - HASH_EVERY * 8:
			my_hashes.erase(k)

## Packet: [start, inputs..., ack, frame, adv, hash_frame, hash]
func make_packet() -> PackedByteArray:
	var start := remote_ack + 1
	var last := frame + DELAY - 1
	var ins := PackedInt32Array()
	for f in range(start, mini(last, start + SEND_MAX - 1) + 1):
		ins.append(local_in.get(f, 0))
	var hf := last_hash_frame
	var pkt := [start, ins, remote_last, frame, frame - remote_frame, hf, my_hashes.get(hf, 0)]
	return var_to_bytes(pkt)

func on_packet(bytes: PackedByteArray) -> void:
	var pkt = bytes_to_var(bytes)
	if not (pkt is Array) or pkt.size() != 7:
		return
	var start: int = pkt[0]
	var ins: PackedInt32Array = pkt[1]
	for i in ins.size():
		var g := start + i
		if g != remote_last + 1:
			continue
		var b: int = ins[i]
		remote_in[g] = b
		remote_last = g
		if g < frame and used.get(g, b) != b:
			if rollback_from < 0 or g < rollback_from:
				rollback_from = g
	remote_ack = maxi(remote_ack, int(pkt[2]))
	if int(pkt[3]) > remote_frame:
		remote_frame = pkt[3]
		remote_adv = pkt[4]
	if int(pkt[5]) > 0:
		remote_hashes[int(pkt[5])] = int(pkt[6])

## Frames of input we have predicted but not yet confirmed.
func unconfirmed() -> int:
	return maxi(0, frame - 1 - remote_last)
