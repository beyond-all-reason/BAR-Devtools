---@meta dsl

--- The Transfer vocabulary transfer contributes to the mission sandbox. It is
--- the same verb the mode grammar governs: what a mission hands over goes
--- through the pipeline a mode's .Allow(Transfer.Units) opens, so a mode that
--- denies unit transfer denies this one too.
---@class MissionTransfer
---@field Units fun(group: MissionUnitGroup, team: MissionTeam): MissionEffect

---@type MissionTransfer
Transfer = {}
