---@meta mission_dsl

--- The Transfer vocabulary transfer contributes to the mission sandbox, over
--- the same pipeline the mode grammar governs. Units asks the active mode, so
--- .Deny(Transfer.Units) refuses a mission's handover exactly as it refuses a
--- player's. Give does not ask. A mission is not privileged for being a
--- mission — it is privileged where its author wrote Give.
---@class MissionTransfer
---@field Units fun(group: MissionUnitGroup, team: MissionTeam): MissionEffect
---@field Give fun(group: MissionUnitGroup, team: MissionTeam): MissionEffect

---@type MissionTransfer
Transfer = {}
