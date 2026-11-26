class_name Inp
## One frame of player input packed into an int bitmask.
## This is all the sim ever sees, so it is also what goes over the network.

const LEFT := 1
const RIGHT := 2
const UP := 4
const DOWN := 8
const ATTACK := 16
const SPECIAL := 32
const JUMP := 64
const BALL := 128
const SHIELD := 256
const BURST := 512
const C_LEFT := 1024   # right stick (smash attacks / aerials)
const C_RIGHT := 2048
const C_UP := 4096
const C_DOWN := 8192
const SMASH := 16384   # "this attack is a smash" (stick flick or keyboard modifier)
const GRAB := 32768
const START := 65536
const BACK := 131072      # Select / Back / View (menus only)
const DASH := 262144      # stick flicked hard sideways this frame (or keyboard tap)
const WALK_SLOW := 524288 # stick only partly pushed: slow walk

const C_ANY := C_LEFT | C_RIGHT | C_UP | C_DOWN

## Buffered buttons: index into Fighter.buf
const BUFFERED := [ATTACK, SPECIAL, JUMP, BALL, SHIELD, GRAB, BURST, C_LEFT, C_RIGHT, C_UP, C_DOWN, DASH]

static func sx(i: int) -> int:
	return (1 if i & RIGHT else 0) - (1 if i & LEFT else 0)

static func sy_up(i: int) -> int:
	return (1 if i & UP else 0) - (1 if i & DOWN else 0)

static func cx(i: int) -> int:
	return (1 if i & C_RIGHT else 0) - (1 if i & C_LEFT else 0)

static func cy_up(i: int) -> int:
	return (1 if i & C_UP else 0) - (1 if i & C_DOWN else 0)
