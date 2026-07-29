# test6_lanes.s -- per-lane divergent DATA (not divergent control flow).
#
# This is the test test0 never gets near. Every lane computes a DIFFERENT
# address from x30 (its lane_id, preloaded at reset) and stores a DIFFERENT
# value there, so shared_mem's arbiter has to actually service all 8 lanes
# with 8 distinct addresses instead of granting the same one repeatedly. If
# the round-robin exclusion in shared_mem is broken -- or if scheduler.sv
# stops stalling before every lane has been serviced -- lanes silently get
# each other's data, or the run hangs.
#
# lane i:  mem[0x1000 + 4*i] = 10*i + 3

li   x1, 0x1000
slli x2, x30, 2         # lane_id * 4
add  x3, x1, x2         # this lane's own address

addi x4, x0, 10
mul  x5, x30, x4        # lane_id * 10
addi x5, x5, 3          # lane_id * 10 + 3

sw   x5, 0(x3)
lw   x6, 0(x3)          # read it straight back -- must equal x5

# also prove lanes did NOT all write the same place: read lane 0's slot,
# which every lane can address identically. It must hold 3, not 73.
lw   x7, 0(x1)

done
