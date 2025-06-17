-- ICE HUB V2 - QBA
-- ALL-IN-ONE SCRIPT (Consolidated from Modular Version)
-- Designed for advanced physics, prediction, visualization, UI, and features.
-- by [Icecube1214] 

-- IMPORTANT NOTE ON SETTINGS PERSISTENCE:
-- This script uses a client-side attribute (`ReplicatedStorage:SetAttribute`) to save your settings.
-- This means your settings will persist for YOU on the SAME DEVICE.
-- If you play on a different device or if Roblox clears your local cache, settings may reset.
-- For server-wide, cross-device persistence (e.g., in a full game), Roblox's DataStoreService
-- would be required, which involves server-side scripting. This script is client-side only.

-- ====================================================================================================
-- SERVICES & GLOBAL VARIABLES (Shared Across All Logic)
-- ====================================================================================================
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local Debris = game:GetService("Debris") -- For cleaning up temporary parts
local SoundService = game:GetService("SoundService")
local HttpService = game:GetService("HttpService") -- For JSON encoding/decoding for config
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Direct access for attributes
local StarterGui = game:GetService("StarterGui") -- For setting clipboard (requires game to allow it)

local LocalPlayer = Players.LocalPlayer

-- ====================================================================================================
-- UTILITY FUNCTIONS (Used by multiple sections)
-- ====================================================================================================

-- Utility for deep copying tables (important for nested settings)
local function deepCopy(orig)
    local orig_type = typeof(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for k, v in pairs(orig) do
            copy[deepCopy(k)] = deepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

-- ====================================================================================================
-- SETTINGS MANAGER LOGIC
-- ====================================================================================================

local CONFIG_SAVE_KEY = "IceHubPassTrainerConfig_V2" -- Updated key for versioning
local PROFILE_SAVE_KEY = "IceHubPassTrainerProfiles_V2" -- New key for profiles

-- DEFAULT SETTINGS
-- This table defines the initial state and structure of all settings.
-- Increment 'Version' when you make breaking changes or add new defaults that old saves won't have.
local DefaultSettings = {
    Version = 4, -- CURRENT SETTINGS SCHEMA VERSION (Incremented for new features/structure)
    Enabled = false,
    Gravity = 196.2, -- Roblox's default Workspace.Gravity.
    BeamEnabled = true,
    ArcEnabled = true,
    DangerCheck = true,
    VisualsCleanupTime = 0.1, -- How long before old arc parts are cleaned up
    BeepCooldown = 0.5, -- Minimum time between safe pass audible beeps
    BeepSoundId = "rbxassetid://135830911", -- !!! IMPORTANT: REPLACE WITH YOUR DESIRED SOUND ID !!!

    ThrowStyles = {
        BULLET = {BasePower = 100, VertBias = 0.8},
        LOFT = {BasePower = 70, VertBias = 1.8},
        MAG = {BasePower = 85, VertBias = 1.3},
        FADE = {BasePower = 90, VertBias = 1.1},
    },
    CurrentStyle = "BULLET",

    AutoLock = false,
    AutoPowerEnabled = true, -- Scales throw power based on receiver distance
    MaxDistancePowerScale = 150,
    MinPowerScaleFactor = 0.7,

    DefenderCheckSettings = {
        InterceptionRadius = 3,
        DefenderReactionTime = 0.3,
        DefenderJumpHeight = 8,
        DefenderDiveReach = 5,
        -- New: Defender weighting (0-1, 1 = full effect, 0 = no effect)
        WeightBehind = 0.5, -- How much to weigh defenders behind the ball's path
        WeightSide = 0.8,   -- How much to weigh defenders to the side of the ball's path
    },

    QBReleaseDelay = 0.1,

    LeadSpotEnabled = true,
    LeadSpotSize = 0.8,
    LeadSpotColor = Color3.fromRGB(0, 255, 0),

    ReceiverPredictionAccuracy = 0.8,
    ReceiverPredictionLookAheadTime = 0.5,
    ReceiverMaxAcceleration = 60,

    ManualModeEnabled = false,
    GUI_Position = UDim2.new(0.5, -160, 0.5, -145), -- Default GUI position (centered)
    GUI_Minimized = false, -- New setting for minimize/expand
}

-- ACTIVE SETTINGS - This is the primary table that all parts of the script read from.
local Settings = deepCopy(DefaultSettings)

-- RUNTIME STATE - Variables that do not need to be saved/loaded with settings.
local RuntimeState = {
    LockTarget = nil, -- Currently locked target player instance
    LastSafePassTime = 0, -- For sound beep cooldown
    ProfileNamesCache = {}, -- For quick access to profile names
}

-- PROFILE DATA
local PlayerProfiles = {}
local CurrentProfileName = "Default"

-- Event to notify listeners when settings change (for GUI updates)
local SettingsChanged = Instance.new("BindableEvent")
local ProfileChanged = Instance.new("BindableEvent")

-- Helper to apply loaded/default values, only for keys that exist in DefaultSettings
local function applySettings(targetTable, sourceTable)
    for k, v in pairs(DefaultSettings) do -- Iterate DefaultSettings to ensure we only apply known keys
        if sourceTable[k] ~= nil then -- Check if the key exists in the source (loaded) data
            if typeof(v) == 'table' and typeof(sourceTable[k]) == 'table' then
                -- Deep copy nested tables to ensure independence and proper structure
                targetTable[k] = deepCopy(sourceTable[k])
            else
                -- Directly assign for non-table values
                targetTable[k] = sourceTable[k]
            end
        else
            -- If a setting is missing from the loaded data, use its default value
            targetTable[k] = deepCopy(v)
        end
    end
end

-- SAVE/LOAD SETTINGS
local function SaveSettings()
    local success, err = pcall(function()
        -- Ensure GUI position and minimized state are up-to-date before saving
        if mainFrame then -- mainFrame will be defined in UIManager section below
            Settings.GUI_Position = mainFrame.Position
            Settings.GUI_Minimized = not mainFrame.MainContentFrame.Visible -- If content is hidden, GUI is minimized
        end

        local savableSettings = deepCopy(Settings)
        -- No need to explicitly nil out LockTarget/LastSafePassTime from savableSettings
        -- if they are never put INTO Settings from DefaultSettings/loaded data.
        -- They are now explicitly in RuntimeState.

        local json = HttpService:JSONEncode(savableSettings)
        ReplicatedStorage:SetAttribute(CONFIG_SAVE_KEY, json)
        -- print("[SettingsManager] Settings saved.")
    end)
    if not success then
        warn("[SettingsManager] Failed to save settings: " .. err)
    end
end

local function LoadSettings()
    local success, err = pcall(function()
        local json = ReplicatedStorage:GetAttribute(CONFIG_SAVE_KEY)
        if json then
            local loadedSettings = HttpService:JSONDecode(json)
            local savedVersion = loadedSettings.Version or 0

            -- --- SETTINGS MIGRATION LOGIC ---
            if savedVersion < DefaultSettings.Version then
                warn("[SettingsManager] Migrating old settings from version " .. savedVersion .. " to " .. DefaultSettings.Version)
                -- For any new settings introduced in DefaultSettings that don't exist in loadedSettings,
                -- ensure they get their default values from DefaultSettings.
                for k, v in pairs(DefaultSettings) do
                    if loadedSettings[k] == nil then
                        loadedSettings[k] = deepCopy(v)
                    end
                end
                loadedSettings.Version = DefaultSettings.Version -- Update the loaded settings' version to current
            end
            -- --- END MIGRATION LOGIC ---

            applySettings(Settings, loadedSettings)
        end
    end)
    if not success then
        warn("[SettingsManager] Failed to load settings: " .. err)
    end
end

local function ResetSettings()
    applySettings(Settings, DefaultSettings)
    RuntimeState.LockTarget = nil -- Reset runtime target
    RuntimeState.LastSafePassTime = 0 -- Reset runtime timer
    SaveSettings()
    SettingsChanged:Fire() -- Notify GUI to update
    print("[SettingsManager] Settings reset to defaults.")
end

-- PROFILE MANAGEMENT
local function RefreshProfileNamesCache()
    RuntimeState.ProfileNamesCache = {}
    for name, _ in pairs(PlayerProfiles) do
        table.insert(RuntimeState.ProfileNamesCache, name)
    end
    table.sort(RuntimeState.ProfileNamesCache)
    -- Ensure "Default" is always the first option if it exists, or is added.
    if not table.find(RuntimeState.ProfileNamesCache, "Default") then
        table.insert(RuntimeState.ProfileNamesCache, 1, "Default")
    end
end

local function SaveProfiles()
    local success, err = pcall(function()
        local json = HttpService:JSONEncode(PlayerProfiles)
        ReplicatedStorage:SetAttribute(PROFILE_SAVE_KEY, json)
        -- print("[SettingsManager] Profiles saved.")
    end)
    if not success then
        warn("[SettingsManager] Failed to save profiles: " .. err)
    end
end

local function LoadProfiles()
    local success, err = pcall(function()
        local json = ReplicatedStorage:GetAttribute(PROFILE_SAVE_KEY)
        if json then
            PlayerProfiles = HttpService:JSONDecode(json)
            -- print("[SettingsManager] Profiles loaded.")
        end
    end)
    if not success then
        warn("[SettingsManager] Failed to load profiles: " .. err)
    end
    RefreshProfileNamesCache()
end

local function LoadProfile(profileName)
    if profileName == "Default" then
        ResetSettings() -- Load defaults for "Default" profile
        CurrentProfileName = "Default"
        SettingsChanged:Fire()
        ProfileChanged:Fire()
        print("[SettingsManager] Loaded profile: " .. profileName)
        return
    end

    if PlayerProfiles[profileName] then
        applySettings(Settings, PlayerProfiles[profileName])
        CurrentProfileName = profileName
        SaveSettings() -- Save active settings to persist the loaded profile for next session
        SettingsChanged:Fire()
        ProfileChanged:Fire()
        print("[SettingsManager] Loaded profile: " .. profileName)
    else
        warn("[SettingsManager] Profile not found: " .. profileName)
    end
end

local function SaveCurrentProfile(profileName)
    if profileName and string.len(profileName) > 0 then
        -- Ensure we save the current state of Settings, not including runtime states
        PlayerProfiles[profileName] = deepCopy(Settings)
        CurrentProfileName = profileName
        SaveProfiles()
        RefreshProfileNamesCache() -- Update cache after saving
        ProfileChanged:Fire()
        print("[SettingsManager] Saved current settings as profile: " .. profileName)
    else
        warn("[SettingsManager] Invalid profile name provided.")
    end
end

local function DeleteProfile(profileName)
    if PlayerProfiles[profileName] then
        PlayerProfiles[profileName] = nil
        if CurrentProfileName == profileName then
            CurrentProfileName = "Default" -- If deleting active profile, revert current name
            ResetSettings() -- Load defaults if active profile is deleted
        end
        SaveProfiles()
        RefreshProfileNamesCache() -- Update cache after deleting
        ProfileChanged:Fire()
        print("[SettingsManager] Deleted profile: " .. profileName)
    else
        warn("[SettingsManager] Profile not found: " .. profileName)
    end
end

-- Export/Import Settings
local function ExportSettingsToJson()
    local savableSettings = deepCopy(Settings)
    -- Remove GUI position and minimized state for sharing, as it's device-specific UX
    savableSettings.GUI_Position = nil
    savableSettings.GUI_Minimized = nil
    local jsonString = HttpService:JSONEncode(savableSettings)
    pcall(function() -- Wrap in pcall as SetClipboard may fail in some contexts
        StarterGui:SetCore("SetClipboard", jsonString)
        warn("[SettingsManager] Settings JSON copied to clipboard!")
    end)
end

local function ImportSettingsFromJson()
    local jsonString = StarterGui:GetCore("GetClipboard")
    if not jsonString or string.len(jsonString) == 0 then
        warn("[SettingsManager] Clipboard is empty or does not contain text.")
        return
    end

    local success, loadedSettings = pcall(function()
        return HttpService:JSONDecode(jsonString)
    end)

    if success and typeof(loadedSettings) == "table" and loadedSettings.Version ~= nil then
        -- Apply loaded settings to current Settings table
        local savedVersion = loadedSettings.Version or 0
        if savedVersion < DefaultSettings.Version then
            warn("[SettingsManager] Imported settings from older version " .. savedVersion .. ". Attempting migration.")
            for k, v in pairs(DefaultSettings) do
                if loadedSettings[k] == nil then
                    loadedSettings[k] = deepCopy(v)
                end
            end
            loadedSettings.Version = DefaultSettings.Version
        end

        applySettings(Settings, loadedSettings)
        SaveSettings()
        SettingsChanged:Fire()
        print("[SettingsManager] Settings imported successfully!")
    else
        warn("[SettingsManager] Failed to import settings from clipboard. Invalid JSON or format.")
    end
end


-- Initialize: Load settings and profiles when this section of the script starts
LoadSettings()
LoadProfiles()

-- Preload the sound for efficiency
local safePassSound = Instance.new("Sound")
safePassSound.SoundId = Settings.BeepSoundId
safePassSound.Volume = 0.5
safePassSound.Parent = Camera -- Parent to Camera for local playback
SoundService:PreloadAsync({safePassSound}) -- Preload it

-- ====================================================================================================
-- TRAJECTORY MATH LOGIC
-- ====================================================================================================

local TrajectoryMath = {} -- Define the local table for TrajectoryMath functions

function TrajectoryMath.GetThrowVelocityAndTrajectory(originPos, targetInitialPos, targetVel, basePower, verticalBias, gravity, qbReleaseDelay)
    local delayedTargetInitialPos = targetInitialPos + targetVel * qbReleaseDelay

    local maxIterations = 20
    local timeToTarget = (delayedTargetInitialPos - originPos).Magnitude / basePower
    timeToTarget = math.max(0.01, timeToTarget)

    local bestVelocity = Vector3.zero
    local estimatedLandingPos = delayedTargetInitialPos

    local gravityVector = Vector3.new(0, -gravity, 0)

    for i = 1, maxIterations do
        estimatedLandingPos = targetInitialPos + targetVel * (timeToTarget + qbReleaseDelay)
        local displacement = estimatedLandingPos - originPos
        local displacementXZ = Vector3.new(displacement.X, 0, displacement.Z)
        local distanceXZ = displacementXZ.Magnitude

        if distanceXZ < 0.1 then
             local heightDiff = displacement.Y
             local initialVy = (heightDiff / timeToTarget) - (0.5 * gravity * timeToTarget)
             bestVelocity = Vector3.new(0, initialVy, 0)
             if bestVelocity.Magnitude > 0 then
                 bestVelocity = bestVelocity.Unit * basePower
             else
                 bestVelocity = Vector3.new(0, basePower, 0)
             end
             timeToTarget = math.max(0.01, (heightDiff > 0 and (initialVy + math.sqrt(initialVy^2 + 2 * gravity * heightDiff)) / gravity)
                         or (heightDiff < 0 and (-initialVy + math.sqrt(-initialVy^2 + 2 * gravity * heightDiff)) / gravity)
                         or 0.01)
             break
        end

        local requiredVy = (displacement.Y / timeToTarget) - (0.5 * gravity * timeToTarget)
        requiredVy = requiredVy * verticalBias

        local vxzMagnitude = distanceXZ / timeToTarget
        local vxzDirection = displacementXZ.Unit

        local potentialVelocity = (vxzDirection * vxzMagnitude) + Vector3.new(0, requiredVy, 0)

        if potentialVelocity.Magnitude > 0 then
            potentialVelocity = potentialVelocity.Unit * basePower
        end

        bestVelocity = potentialVelocity

        local newTimeToTarget = (estimatedLandingPos - originPos).Magnitude / basePower
        newTimeToTarget = math.max(0.01, newTimeToTarget)
        if math.abs(newTimeToTarget - timeToTarget) < 0.01 then
            timeToTarget = newTimeToTarget
            break
        end
        timeToTarget = newTimeToTarget
    end

    estimatedLandingPos = originPos + bestVelocity * timeToTarget + 0.5 * gravityVector * (timeToTarget^2)

    return bestVelocity, timeToTarget, estimatedLandingPos
end


-- ====================================================================================================
-- RECEIVER PREDICTION LOGIC
-- ====================================================================================================

local ReceiverPrediction = {} -- Define the local table for ReceiverPrediction functions

function ReceiverPrediction.PredictReceiverPosition(receiverHrp, timeAhead)
    local currentPos = receiverHrp.Position
    local currentVel = receiverHrp.AssemblyLinearVelocity
    local humanoid = receiverHrp.Parent:FindFirstChildOfClass("Humanoid")
    local walkSpeed = humanoid and humanoid.WalkSpeed or 16

    local targetVelMagnitude = currentVel.Magnitude
    if targetVelMagnitude < walkSpeed then
        targetVelMagnitude = math.min(walkSpeed, targetVelMagnitude + Settings.ReceiverMaxAcceleration * timeAhead) -- Settings is already in scope
    end

    local projectedVel = currentVel.Unit * targetVelMagnitude
    local blendedVel = currentVel:Lerp(projectedVel, Settings.ReceiverPredictionAccuracy) -- Settings is already in scope

    local predictedPos = currentPos + blendedVel * timeAhead

    return predictedPos, blendedVel
end

function ReceiverPrediction.GetClosestTarget()
    local closest = nil
    local shortest = math.huge
    local localHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not localHrp then return nil end

    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Team ~= LocalPlayer.Team then
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen then
                local dist = (Vector2.new(screenPos.X, screenPos.Y) - Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)).Magnitude
                if dist < shortest then
                    shortest = dist
                    closest = player
                end
            end
        end
    end
    return closest
end

-- ====================================================================================================
-- DEFENDER PREDICTION LOGIC
-- ====================================================================================================

local DefenderPrediction = {} -- Define the local table for DefenderPrediction functions

-- Checks if any defender can intercept the ball's trajectory
-- ballTrajectoryPoints: a table of {pos, time} points along the ball's path
function DefenderPrediction.CheckForDanger(ballTrajectoryPoints, originPos, throwVelocity)
    -- Settings is already in scope (from SettingsManager)
    -- ReceiverPrediction is already in scope (from ReceiverPrediction module)

    local targetPlayer = RuntimeState.LockTarget -- Use RuntimeState
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
        return false -- No valid target, so no interception risk
    end

    local danger = false
    for _, defenderPlayer in pairs(Players:GetPlayers()) do
        if defenderPlayer ~= LocalPlayer and defenderPlayer ~= targetPlayer and defenderPlayer.Team ~= LocalPlayer.Team and defenderPlayer.Character and defenderPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local defenderHrp = defenderPlayer.Character.HumanoidRootPart

            for _, point in pairs(ballTrajectoryPoints) do
                local ballPosAtTime = point.pos
                local timeOfBallAtPoint = point.time

                -- Defender needs time to react and move after QB releases ball
                if timeOfBallAtPoint < Settings.QBReleaseDelay + Settings.DefenderCheckSettings.DefenderReactionTime then continue end

                local timeForDefenderToReact = timeOfBallAtPoint - Settings.QBReleaseDelay
                if timeForDefenderToReact < Settings.DefenderCheckSettings.DefenderReactionTime then continue end

                local defenderPredictedPosAtBallTime, _ = ReceiverPrediction.PredictReceiverPosition(
                    defenderHrp,
                    timeForDefenderToReact
                )

                local horizontalDistToBall = Vector3.new(defenderPredictedPosAtBallTime.X, 0, defenderPredictedPosAtBallTime.Z) - Vector3.new(ballPosAtTime.X, 0, ballPosAtTime.Z)
                local verticalDistToBall = ballPosAtTime.Y - defenderPredictedPosAtBallTime.Y

                local effectiveReachHorizontal = Settings.DefenderCheckSettings.InterceptionRadius + Settings.DefenderCheckSettings.DefenderDiveReach
                local effectiveReachVertical = Settings.DefenderCheckSettings.InterceptionRadius + Settings.DefenderCheckSettings.DefenderJumpHeight

                local weightedRadius = Settings.DefenderCheckSettings.InterceptionRadius

                -- Apply weighting based on defender's position relative to ball path
                -- Vector from QB to Ball (current point)
                local qbToBallDir = (ballPosAtTime - originPos).Unit
                -- Vector from QB to Defender (from ball point to defender)
                local ballToDefenderDir = (defenderPredictedPosAtBallTime - ballPosAtTime).Unit

                -- Angle between ball's forward path and defender's position relative to ball
                local dotProduct = qbToBallDir:Dot(ballToDefenderDir)

                -- Check if defender is generally 'behind' or 'to the side' of the ball's direction of travel
                if dotProduct < -0.5 then -- Defender is significantly "behind" the ball's current direction
                    weightedRadius = weightedRadius * Settings.DefenderCheckSettings.WeightBehind
                elseif dotProduct < 0.5 then -- Defender is somewhat to the "side" (e.g., within 60-120 degrees off forward)
                    weightedRadius = weightedRadius * Settings.DefenderCheckSettings.WeightSide
                end

                if horizontalDistToBall.Magnitude < (effectiveReachHorizontal * weightedRadius) and math.abs(verticalDistToBall) < effectiveReachVertical then
                    danger = true
                    break
                end
            end
        end
        if danger then break end
    end
    return danger
end

-- ====================================================================================================
-- UI MANAGER LOGIC
-- ====================================================================================================

local UIManager = {} -- Define the local table for UIManager functions

-- Local references for visuals (managed by UIManager)
local beamLine = nil
local landingPart = nil
local dangerLabel = nil
local statusLabel = nil
local keysLabel = nil
local arcParts = {}
local arcBeams = {} -- For alternative beam visualization
local arcAttachments = {} -- For alternative beam visualization
local mainGui = nil
local mainFrame = nil -- This will be the main GUI frame, referenced by SaveSettings
local mainContentFrame = nil -- Frame that holds all content to be minimized/maximized
local leadSpotPart = nil

-- --- VISUALS RENDERING FUNCTIONS ---

function UIManager.DrawBeam(originPos, targetPos)
    if not beamLine then
        beamLine = Instance.new("Beam")
        beamLine.Parent = Camera
        local a0 = Instance.new("Attachment", Camera)
        local a1 = Instance.new("Attachment", Workspace.Terrain)
        beamLine.Attachment0 = a0
        beamLine.Attachment1 = a1
        beamLine.Color = ColorSequence.new(Color3.fromRGB(0, 180, 255))
        beamLine.Transparency = NumberSequence.new(0.1)
        beamLine.Segments = 1
        beamLine.Width0 = 0.2
        beamLine.Width1 = 0.05
    end
    beamLine.Attachment0.WorldPosition = originPos
    beamLine.Attachment1.WorldPosition = targetPos
    beamLine.Enabled = Settings.BeamEnabled -- Settings is already in scope
end

function UIManager.HideBeam()
    if beamLine then beamLine.Enabled = false end
end

function UIManager.DrawArc(originPos, initialVelocity, gravity, distanceToTarget)
    -- Settings is already in scope

    -- Cleanup existing arc visuals
    for _, part in pairs(arcParts) do
        Debris:AddItem(part, Settings.VisualsCleanupTime)
    end
    arcParts = {}
    for _, beam in pairs(arcBeams) do
        Debris:AddItem(beam, Settings.VisualsCleanupTime)
    end
    arcBeams = {}
    for _, att in pairs(arcAttachments) do
        Debris:AddItem(att, Settings.VisualsCleanupTime)
    end
    arcAttachments = {}

    if not Settings.ArcEnabled then return end

    local simulationTimeStep = 0.05 -- Default
    if distanceToTarget > 100 then
        simulationTimeStep = 0.02 -- Finer steps for longer distances
    elseif distanceToTarget > 50 then
        local factor = (distanceToTarget - 50) / 50
        simulationTimeStep = 0.05 - (0.03 * factor)
    end
    simulationTimeStep = math.max(0.01, simulationTimeStep)

    local maxFlightTime = 5

    local currentPos = originPos
    local currentVel = initialVelocity
    local gravityVector = Vector3.new(0, -gravity, 0)

    for t = 0, maxFlightTime, simulationTimeStep do
        local nextPos = currentPos + currentVel * simulationTimeStep + 0.5 * gravityVector * (simulationTimeStep^2)
        local nextVel = currentVel + gravityVector * simulationTimeStep

        local segment = Instance.new("Part")
        segment.Parent = Workspace
        segment.Anchored = true
        segment.CanCollide = false
        segment.Transparency = 0.4
        segment.BrickColor = BrickColor.new("Cyan")
        segment.Material = Enum.Material.Neon
        segment.FormFactor = Enum.FormFactor.Symmetric
        segment.Size = Vector3.new(0.2, 0.2, (nextPos - currentPos).Magnitude)
        segment.CFrame = CFrame.new(currentPos:Lerp(nextPos, 0.5), nextPos)
        table.insert(arcParts, segment)

        currentPos = nextPos
        currentVel = nextVel

        if currentPos.Y < Workspace.Terrain.MinY.Y - 5 then
            break
        end
    end
end

function UIManager.HideArc()
    for _, part in pairs(arcParts) do Debris:AddItem(part, Settings.VisualsCleanupTime) end
    arcParts = {}
    for _, beam in pairs(arcBeams) do Debris:AddItem(beam, Settings.VisualsCleanupTime) end
    arcBeams = {}
    for _, att in pairs(arcAttachments) do Debris:AddItem(att, Settings.VisualsCleanupTime) end
    arcAttachments = {}
end

function UIManager.DrawLanding(pos)
    -- Settings is already in scope
    if not landingPart then
        landingPart = Instance.new("Part", Workspace)
        landingPart.Anchored = true
        landingPart.CanCollide = false
        landingPart.Size = Vector3.new(1.5, 0.5, 1.5)
        landingPart.Transparency = 0.4
        landingPart.Color = Color3.fromRGB(0, 150, 255)
        landingPart.Material = Enum.Material.Neon
        local decal = Instance.new("Decal", landingPart)
        decal.Texture = "rbxassetid://6258019682"
        decal.Face = Enum.NormalId.Top
    end
    landingPart.Position = pos
    landingPart.Transparency = 0.4
end

function UIManager.HideLanding()
    if landingPart then landingPart.Transparency = 1 end
end

function UIManager.DrawLeadSpot(pos)
    -- Settings is already in scope
    if not leadSpotPart then
        leadSpotPart = Instance.new("Part", Workspace)
        leadSpotPart.Anchored = true
        leadSpotPart.CanCollide = false
        leadSpotPart.Shape = Enum.PartType.Ball
        leadSpotPart.Material = Enum.Material.Neon
    end
    leadSpotPart.Position = pos + Vector3.new(0, Settings.LeadSpotSize/2 + 0.1, 0)
    leadSpotPart.Size = Vector3.new(Settings.LeadSpotSize, Settings.LeadSpotSize, Settings.LeadSpotSize)
    leadSpotPart.Color = Settings.LeadSpotColor
    leadSpotPart.Transparency = 0.2
end

function UIManager.HideLeadSpot()
    if leadSpotPart then leadSpotPart.Transparency = 1 end
end

-- --- GUI CREATION AND UPDATES ---

local dragging = false
local dragInput = nil
local dragStart = nil
local startPos = nil

local function SetupDraggableGUI(guiFrame)
    local function onInputBegan(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = guiFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.Ended then
                    dragging = false
                    SaveSettings() -- Save position when dragging ends
                end
            end)
        end
    end

    local function onInputChanged(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                local delta = input.Position - dragStart
                guiFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end
    end

    guiFrame.InputBegan:Connect(onInputBegan)
    guiFrame.InputChanged:Connect(onInputChanged)

    local topBar = guiFrame:FindFirstChild("TopBar")
    if topBar then
        topBar.InputBegan:Connect(onInputBegan)
        topBar.InputChanged:Connect(onInputChanged)
    end
end

-- Helper to create styled buttons
local function CreateStyledButton(parent, name, text, onClick)
    local button = Instance.new("TextButton", parent)
    button.Name = name
    button.Size = UDim2.new(1, 0, 0, 28)
    button.BackgroundTransparency = 0.8
    button.BackgroundColor3 = Color3.fromRGB(30, 40, 50)
    button.TextColor3 = Color3.fromRGB(200, 220, 255)
    button.Font = Enum.Font.SourceSansBold
    button.TextSize = 16
    button.Text = text
    button.BorderSizePixel = 0
    button.ZIndex = 2

    local corner = Instance.new("UICorner", button)
    corner.CornerRadius = UDim.new(0, 5)
    local stroke = Instance.new("UIStroke", button)
    stroke.Color = Color3.fromRGB(0, 180, 255)
    stroke.Transparency = 0.5
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.UIStrokeApplyMode.Border

    button.MouseButton1Click:Connect(onClick)
    return button
end

-- Helper to create dropdown menu
local function CreateDropdown(parent, name, options, onSelect)
    local frame = Instance.new("Frame", parent)
    frame.Name = name .. "DropdownFrame"
    frame.Size = UDim2.new(1, 0, 0, 28)
    frame.BackgroundTransparency = 1
    frame.ZIndex = 2

    local currentSelectionButton = CreateStyledButton(frame, name .. "SelectionBtn", options[1] or "Select...", function()
        -- Toggle dropdown list visibility
        local list = frame:FindFirstChild(name .. "List")
        if list then list.Visible = not list.Visible end
    end)
    currentSelectionButton.Size = UDim2.new(1, 0, 1, 0)
    currentSelectionButton.LayoutOrder = 1 -- Important for UIListLayout

    local listFrame = Instance.new("Frame", frame)
    listFrame.Name = name .. "List"
    listFrame.Size = UDim2.new(1, 0, 0, 0) -- Height will be set dynamically
    listFrame.Position = UDim2.new(0, 0, 1, 0)
    listFrame.BackgroundColor3 = Color3.fromRGB(30, 40, 50)
    listFrame.BackgroundTransparency = 0.1
    listFrame.BorderSizePixel = 0
    listFrame.ZIndex = 3
    listFrame.Visible = false

    local listLayout = Instance.new("UIListLayout", listFrame)
    listLayout.FillDirection = Enum.FillDirection.Vertical
    listLayout.Padding = UDim.new(0, 2)

    local listCorner = Instance.new("UICorner", listFrame)
    listCorner.CornerRadius = UDim.new(0, 5)
    local listStroke = Instance.new("UIStroke", listFrame)
    listStroke.Color = Color3.fromRGB(0, 180, 255)
    listStroke.Transparency = 0.5
    listStroke.Thickness = 1
    listStroke.ApplyStrokeMode = Enum.UIStrokeApplyMode.Border

    for i, option in ipairs(options) do
        local itemButton = Instance.new("TextButton", listFrame)
        itemButton.Name = "Item" .. option
        itemButton.Size = UDim2.new(1, 0, 0, 25)
        itemButton.BackgroundTransparency = 1
        itemButton.TextColor3 = Color3.fromRGB(180, 200, 230)
        itemButton.Font = Enum.Font.SourceSans
        itemButton.TextSize = 15
        itemButton.TextXAlignment = Enum.TextXAlignment.Left
        itemButton.Text = "  " .. option -- Indent slightly
        itemButton.ZIndex = 3

        itemButton.MouseEnter:Connect(function() itemButton.BackgroundTransparency = 0.8; itemButton.BackgroundColor3 = Color3.fromRGB(45, 60, 75) end)
        itemButton.MouseLeave:Connect(function() itemButton.BackgroundTransparency = 1 end)

        itemButton.MouseButton1Click:Connect(function()
            currentSelectionButton.Text = option
            listFrame.Visible = false
            onSelect(option)
        end)
    end
    listFrame.Size = UDim2.new(1, 0, 0, #options * 27) -- Adjust height based on number of options

    return frame, currentSelectionButton, listFrame -- Return the frame and the main button
end


function UIManager.CreateMainGUI()
    if mainGui then return end -- Already created

    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    mainGui = Instance.new("ScreenGui", playerGui)
    mainGui.Name = "IceHubMainGui"
    mainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    mainFrame = Instance.new("Frame", mainGui) -- Assign to global mainFrame
    mainFrame.Name = "MainFrame"
    -- Initial size for expanded state, will be adjusted if minimized
    mainFrame.Size = UDim2.new(0, 320, 0, 500)
    mainFrame.Position = Settings.GUI_Position -- Load saved position, or use default from Settings
    mainFrame.BackgroundColor3 = Color3.fromRGB(20, 25, 30)
    mainFrame.BackgroundTransparency = 0.15
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    mainFrame.CornerRadius = UDim.new(0, 10)

    local uiCorner = Instance.new("UICorner", mainFrame)

    local frameStroke = Instance.new("UIStroke", mainFrame)
    frameStroke.Color = Color3.fromRGB(0, 180, 255)
    frameStroke.Transparency = 0.5
    frameStroke.Thickness = 1.5
    frameStroke.ApplyStrokeMode = Enum.UIStrokeApplyMode.Border

    local teamColor = Color3.fromRGB(0, 150, 255)
    if LocalPlayer.TeamColor then
        teamColor = LocalPlayer.TeamColor.Color
    end

    local topBar = Instance.new("Frame", mainFrame)
    topBar.Name = "TopBar"
    topBar.Size = UDim2.new(1, 0, 0, 35)
    topBar.Position = UDim2.new(0, 0, 0, 0)
    topBar.BackgroundColor3 = Color3.fromRGB(0, 120, 180)
    topBar.BorderSizePixel = 0

    local topBarStroke = Instance.new("UIStroke", topBar)
    topBarStroke.Color = Color3.fromRGB(0, 180, 255)
    topBarStroke.Transparency = 0.3
    topBarStroke.Thickness = 1
    topBarStroke.ApplyStrokeMode = Enum.UIStrokeApplyMode.Border

    local titleLabel = Instance.new("TextLabel", topBar)
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, 0, 1, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.TextColor3 = Color3.fromRGB(240, 248, 255)
    titleLabel.Font = Enum.Font.SourceSansBold
    titleLabel.TextSize = 22
    titleLabel.Text = "🧊 ICE HUB V2: Pass Trainer"
    titleLabel.TextXAlignment = Enum.TextXAlignment.Center

    -- Minimize/Expand Button
    local minimizeButton = Instance.new("TextButton", topBar)
    minimizeButton.Name = "MinimizeButton"
    minimizeButton.Size = UDim2.new(0, 30, 1, 0)
    minimizeButton.Position = UDim2.new(1, -30, 0, 0)
    minimizeButton.BackgroundTransparency = 1
    minimizeButton.TextColor3 = Color3.fromRGB(240, 248, 255)
    minimizeButton.Font = Enum.Font.SourceSansBold
    minimizeButton.TextSize = 24
    minimizeButton.Text = "—" -- Default to minimize icon
    minimizeButton.BorderSizePixel = 0
    minimizeButton.ZIndex = 2
    minimizeButton.MouseButton1Click:Connect(function()
        Settings.GUI_Minimized = not Settings.GUI_Minimized
        SaveSettings()
        UIManager.UpdateGUI()
    end)

    mainContentFrame = Instance.new("Frame", mainFrame) -- Assign to global mainContentFrame
    mainContentFrame.Name = "MainContentFrame"
    mainContentFrame.Size = UDim2.new(1, -20, 1, -45)
    mainContentFrame.Position = UDim2.new(0, 10, 0, 40)
    mainContentFrame.BackgroundTransparency = 1
    mainContentFrame.BorderSizePixel = 0

    local contentLayout = Instance.new("UIListLayout", mainContentFrame)
    contentLayout.FillDirection = Enum.FillDirection.Vertical
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    contentLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    contentLayout.Padding = UDim.new(0, 5)

    local uiPadding = Instance.new("UIPadding", mainContentFrame)
    uiPadding.PaddingTop = UDim.new(0, 5)
    uiPadding.PaddingBottom = UDim.new(0, 5)
    uiPadding.PaddingLeft = UDim.new(0, 0)
    uiPadding.PaddingRight = UDim.new(0, 0)

    -- Info Labels (at the top of mainContentFrame)
    dangerLabel = Instance.new("TextLabel", mainContentFrame)
    dangerLabel.Name = "DangerTextLabel"
    dangerLabel.Size = UDim2.new(1, 0, 0, 30)
    dangerLabel.BackgroundTransparency = 1
    dangerLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
    dangerLabel.TextStrokeTransparency = 0.5
    dangerLabel.Font = Enum.Font.SourceSansBold
    dangerLabel.TextSize = 24
    dangerLabel.Text = ""
    dangerLabel.TextXAlignment = Enum.TextXAlignment.Center
    dangerLabel.ZIndex = 2

    statusLabel = Instance.new("TextLabel", mainContentFrame)
    statusLabel.Name = "StatusLabel"
    statusLabel.Size = UDim2.new(1, 0, 0, 20)
    statusLabel.BackgroundTransparency = 1
    statusLabel.TextColor3 = teamColor
    statusLabel.Font = Enum.Font.SourceSansBold
    statusLabel.TextSize = 16
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Text = ""

    -- Controls Frame (below info labels)
    local controlsFrame = Instance.new("Frame", mainContentFrame)
    controlsFrame.Name = "ControlsFrame"
    controlsFrame.Size = UDim2.new(1, 0, 0, 180) -- Height adjusted for buttons
    controlsFrame.BackgroundTransparency = 1
    controlsFrame.BorderSizePixel = 0

    local controlsLayout = Instance.new("UIListLayout", controlsFrame)
    controlsLayout.FillDirection = Enum.FillDirection.Vertical
    controlsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    controlsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    controlsLayout.Padding = UDim.new(0, 5)

    -- --- Automated Toggle Button Creation ---
    local toggleButtonData = {
        {Name = "Enabled", SettingKey = "Enabled"},
        {Name = "AutoLock", SettingKey = "AutoLock"},
        {Name = "AutoPower", SettingKey = "AutoPowerEnabled"},
        {Name = "Beam", SettingKey = "BeamEnabled"},
        {Name = "Arc", SettingKey = "ArcEnabled"},
        {Name = "LeadSpot", SettingKey = "LeadSpotEnabled"},
        {Name = "DangerCheck", SettingKey = "DangerCheck"},
        {Name = "ManualMode", SettingKey = "ManualModeEnabled"},
    }

    local toggleButtons = {} -- Store references to the created buttons

    for _, data in ipairs(toggleButtonData) do
        local btn = CreateStyledButton(controlsFrame, data.Name .. "Btn", "", function()
            Settings[data.SettingKey] = not Settings[data.SettingKey]
            SaveSettings()
            UIManager.UpdateGUI() -- Update all UI
        end)
        toggleButtons[data.SettingKey] = btn -- Store for easy access in UpdateGUI
    end

    -- Action Buttons
    local lockTargetBtn = CreateStyledButton(controlsFrame, "LockTargetBtn", "Lock Closest Target", function()
        RuntimeState.LockTarget = ReceiverPrediction.GetClosestTarget()
        if RuntimeState.LockTarget then
            print("[ICE HUB V2] Locked: " .. RuntimeState.LockTarget.Name)
        else
            print("[ICE HUB V2] No target found.")
        end
        SaveSettings() -- Save other settings
        UIManager.UpdateGUI()
    end)
    local unlockTargetBtn = CreateStyledButton(controlsFrame, "UnlockTargetBtn", "Unlock Target", function()
        RuntimeState.LockTarget = nil
        print("[ICE HUB V2] Target unlocked.")
        SaveSettings() -- Save other settings
        UIManager.UpdateGUI()
    end)

    -- Throw Style Dropdown
    local styleNames = {}
    for name, _ in pairs(Settings.ThrowStyles) do
        table.insert(styleNames, name)
    end
    table.sort(styleNames)

    local styleDropdownFrame, styleSelectionBtn, styleListFrame = CreateDropdown(controlsFrame, "ThrowStyle", styleNames, function(selectedStyle)
        Settings.CurrentStyle = selectedStyle
        SaveSettings()
        UIManager.UpdateGUI()
    end)
    styleSelectionBtn.Text = "Style: " .. Settings.CurrentStyle

    -- QB Release Delay Adjusters
    local delayFrame = Instance.new("Frame", controlsFrame)
    delayFrame.Name = "DelayFrame"
    delayFrame.Size = UDim2.new(1, 0, 0, 28)
    delayFrame.BackgroundTransparency = 1
    local delayLayout = Instance.new("UIListLayout", delayFrame)
    delayLayout.FillDirection = Enum.FillDirection.Horizontal
    delayLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    delayLayout.Padding = UDim.new(0, 5)

    local delayMinusBtn = CreateStyledButton(delayFrame, "DelayMinusBtn", "- QB Delay", function()
        Settings.QBReleaseDelay = math.max(0, Settings.QBReleaseDelay - 0.01)
        SaveSettings()
        UIManager.UpdateGUI()
    end)
    delayMinusBtn.Size = UDim2.new(0.45, 0, 1, 0)
    delayMinusBtn.TextSize = 14

    local delayPlusBtn = CreateStyledButton(delayFrame, "DelayPlusBtn", "+ QB Delay", function()
        Settings.QBReleaseDelay = math.min(0.5, Settings.QBReleaseDelay + 0.01)
        SaveSettings()
        UIManager.UpdateGUI()
    end)
    delayPlusBtn.Size = UDim2.new(0.45, 0, 1, 0)
    delayPlusBtn.TextSize = 14

    -- Profile Management
    local profileHeader = Instance.new("TextLabel", mainContentFrame)
    profileHeader.Name = "ProfileHeader"
    profileHeader.Size = UDim2.new(1, 0, 0, 20)
    profileHeader.BackgroundTransparency = 1
    profileHeader.TextColor3 = Color3.fromRGB(0, 180, 255)
    profileHeader.Font = Enum.Font.SourceSansBold
    profileHeader.TextSize = 18
    profileHeader.Text = "--- PROFILES ---"
    profileHeader.TextXAlignment = Enum.TextXAlignment.Center

    local profileControlsFrame = Instance.new("Frame", mainContentFrame)
    profileControlsFrame.Name = "ProfileControls"
    profileControlsFrame.Size = UDim2.new(1, 0, 0, 60)
    profileControlsFrame.BackgroundTransparency = 1

    local profileControlsLayout = Instance.new("UIListLayout", profileControlsFrame)
    profileControlsLayout.FillDirection = Enum.FillDirection.Vertical
    profileControlsLayout.Padding = UDim.new(0, 5)

    local profileDropdownFrame, profileSelectionBtn, profileListFrame
    -- Initial options will be filled by UpdateGUI, passing an empty list for creation
    profileDropdownFrame, profileSelectionBtn, profileListFrame = CreateDropdown(profileControlsFrame, "Profile", {}, function(selectedProfile)
        LoadProfile(selectedProfile)
    end)

    local profileActionFrame = Instance.new("Frame", profileControlsFrame)
    profileActionFrame.Name = "ProfileActionFrame"
    profileActionFrame.Size = UDim2.new(1, 0, 0, 28)
    profileActionFrame.BackgroundTransparency = 1
    local profileActionLayout = Instance.new("UIListLayout", profileActionFrame)
    profileActionLayout.FillDirection = Enum.FillDirection.Horizontal
    profileActionLayout.Padding = UDim.new(0, 5)

    local saveProfileBtn = CreateStyledButton(profileActionFrame, "SaveProfileBtn", "Save Current", function()
        local namePrompt = Instance.new("TextBox")
        namePrompt.Size = UDim2.new(0, 200, 0, 30)
        namePrompt.Position = UDim2.new(0.5, -100, 0.5, -15)
        namePrompt.Text = "" -- Start empty for user input
        namePrompt.TextScaled = true
        namePrompt.Parent = LocalPlayer.PlayerGui
        namePrompt.BackgroundColor3 = Color3.fromRGB(30, 40, 50)
        namePrompt.TextColor3 = Color3.fromRGB(200, 220, 255)
        namePrompt.Font = Enum.Font.SourceSans
        namePrompt.TextSize = 16
        namePrompt.PlaceholderText = "Enter profile name"

        local promptCorner = Instance.new("UICorner", namePrompt)
        promptCorner.CornerRadius = UDim.new(0, 5)
        local promptStroke = Instance.new("UIStroke", namePrompt)
        promptStroke.Color = Color3.fromRGB(0, 180, 255)
        promptStroke.Transparency = 0.3
        promptStroke.Thickness = 1

        local function onConfirm()
            if namePrompt.Text ~= "" and namePrompt.Text ~= "New Profile Name" then -- Check against placeholder too
                SaveCurrentProfile(namePrompt.Text)
            else
                warn("Profile name cannot be empty.")
            end
            namePrompt:Destroy()
            UIManager.UpdateGUI() -- Update profile dropdown
        end

        local function onLostFocus(enterPressed)
            if enterPressed then
                onConfirm()
            else
                namePrompt:Destroy()
            end
        end
        namePrompt.FocusLost:Connect(onLostFocus)
        namePrompt.Focused = true
    end)
    saveProfileBtn.Size = UDim2.new(0.48, 0, 1, 0)

    local deleteProfileBtn = CreateStyledButton(profileActionFrame, "DeleteProfileBtn", "Delete Selected", function()
        local selectedProfile = profileSelectionBtn.Text
        if selectedProfile ~= "Select Profile" and selectedProfile ~= "Default" and PlayerProfiles[selectedProfile] then
            DeleteProfile(selectedProfile)
            UIManager.UpdateGUI()
        else
            warn("Cannot delete selected profile or profile not found.")
        end
    end)
    deleteProfileBtn.Size = UDim2.new(0.48, 0, 1, 0)

    -- Export/Import Buttons
    local exportImportFrame = Instance.new("Frame", mainContentFrame)
    exportImportFrame.Name = "ExportImportFrame"
    exportImportFrame.Size = UDim2.new(1, 0, 0, 28)
    exportImportFrame.BackgroundTransparency = 1
    local exportImportLayout = Instance.new("UIListLayout", exportImportFrame)
    exportImportLayout.FillDirection = Enum.FillDirection.Horizontal
    exportImportLayout.Padding = UDim.new(0, 5)

    local exportBtn = CreateStyledButton(exportImportFrame, "ExportBtn", "Export Config (JSON)", ExportSettingsToJson)
    exportBtn.Size = UDim2.new(0.48, 0, 1, 0)

    local importBtn = CreateStyledButton(exportImportFrame, "ImportBtn", "Import Config (JSON)", ImportSettingsFromJson)
    importBtn.Size = UDim2.new(0.48, 0, 1, 0)


    local resetSettingsBtn = CreateStyledButton(mainContentFrame, "ResetSettingsBtn", "Reset All Settings to Default", function()
        ResetSettings()
        UIManager.UpdateGUI() -- Update all UI
    end)

    keysLabel = Instance.new("TextLabel", mainContentFrame)
    keysLabel.Name = "KeysHelpLabel"
    keysLabel.Size = UDim2.new(1, 0, 1, 0)
    keysLabel.BackgroundTransparency = 1
    keysLabel.TextColor3 = Color3.fromRGB(200, 220, 255)
    keysLabel.Font = Enum.Font.SourceSans
    keysLabel.TextSize = 15
    keysLabel.TextXAlignment = Enum.TextXAlignment.Left
    keysLabel.TextYAlignment = Enum.TextYAlignment.Top
    keysLabel.TextWrapped = true
    keysLabel.Text = "" -- Will be updated by UIManager.UpdateGUI

    SetupDraggableGUI(mainFrame)
end

function UIManager.UpdateGUI()
    if not mainGui or not mainFrame then return end

    -- Handle Minimize/Expand State
    local minimizeButton = mainFrame.TopBar.MinimizeButton
    if Settings.GUI_Minimized then
        mainFrame.Size = UDim2.new(0, 320, 0, 35) -- Height of just the top bar
        mainContentFrame.Visible = false
        minimizeButton.Text = "＋" -- Plus symbol to expand
        minimizeButton.TextColor3 = Color3.fromRGB(0, 255, 0) -- Green for expand
    else
        mainFrame.Size = UDim2.new(0, 320, 0, 500) -- Full height
        mainContentFrame.Visible = true
        minimizeButton.Text = "—" -- Minus symbol to minimize
        minimizeButton.TextColor3 = Color3.fromRGB(240, 248, 255) -- White for minimize
    end

    -- Update Toggle Buttons (using the stored references)
    local toggleButtonData = { -- Must match the list used in CreateMainGUI
        {Name = "Enabled", SettingKey = "Enabled"},
        {Name = "AutoLock", SettingKey = "AutoLock"},
        {Name = "AutoPower", SettingKey = "AutoPowerEnabled"},
        {Name = "Beam", SettingKey = "BeamEnabled"},
        {Name = "Arc", SettingKey = "ArcEnabled"},
        {Name = "LeadSpot", SettingKey = "LeadSpotEnabled"},
        {Name = "DangerCheck", SettingKey = "DangerCheck"},
        {Name = "ManualMode", SettingKey = "ManualModeEnabled"},
    }

    for _, data in ipairs(toggleButtonData) do
        local btn = mainContentFrame.ControlsFrame[data.Name .. "Btn"]
        if btn then
            local status = Settings[data.SettingKey] and "ON" or "OFF"
            btn.Text = data.Name .. ": " .. status
        end
    end

    -- Update Throw Style Dropdown
    local styleSelectionBtn = mainContentFrame.ControlsFrame.ThrowStyleDropdownFrame.ThrowStyleSelectionBtn
    styleSelectionBtn.Text = "Style: " .. Settings.CurrentStyle

    -- Update QB Release Delay Text
    local delayText = string.format("QB Delay: %.2fs", Settings.QBReleaseDelay)
    local delayMinusBtn = mainContentFrame.ControlsFrame.DelayFrame.DelayMinusBtn
    local delayPlusBtn = mainContentFrame.ControlsFrame.DelayFrame.DelayPlusBtn
    -- Re-label buttons to show current value
    delayMinusBtn.Text = "- " .. delayText
    delayPlusBtn.Text = "+ " .. delayText

    -- Update Profile Dropdown
    local profileDropdownFrame = mainContentFrame.ProfileControls.ProfileDropdownFrame
    local profileSelectionBtn = profileDropdownFrame.ProfileSelectionBtn
    local profileListFrame = profileDropdownFrame.ProfileList

    -- Clear existing list items
    for _, child in pairs(profileListFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    -- Use the cached profile names
    local profileNames = RuntimeState.ProfileNamesCache

    -- Update profile list dropdown and its height
    for i, option in ipairs(profileNames) do
        local itemButton = Instance.new("TextButton")
        itemButton.Name = "Item" .. option
        itemButton.Size = UDim2.new(1, 0, 0, 25)
        itemButton.BackgroundTransparency = 1
        itemButton.TextColor3 = Color3.fromRGB(180, 200, 230)
        itemButton.Font = Enum.Font.SourceSans
        itemButton.TextSize = 15
        itemButton.TextXAlignment = Enum.TextXAlignment.Left
        itemButton.Text = "  " .. option -- Indent slightly
        itemButton.ZIndex = 3
        itemButton.Parent = profileListFrame

        itemButton.MouseEnter:Connect(function() itemButton.BackgroundTransparency = 0.8; itemButton.BackgroundColor3 = Color3.fromRGB(45, 60, 75) end)
        itemButton.MouseLeave:Connect(function() itemButton.BackgroundTransparency = 1 end)

        itemButton.MouseButton1Click:Connect(function()
            profileSelectionBtn.Text = option
            profileListFrame.Visible = false
            LoadProfile(option)
        end)
    end
    profileListFrame.Size = UDim2.new(1, 0, 0, #profileNames * 27)

    profileSelectionBtn.Text = CurrentProfileName -- Display currently active profile

    -- Update Status Label
    if statusLabel then -- Ensure statusLabel exists
        local tgtName = RuntimeState.LockTarget and RuntimeState.LockTarget.Name or "None" -- Use RuntimeState
        local modeText = Settings.ManualModeEnabled and "MANUAL" or "AUTO"
        local autoPowerStatus = Settings.AutoPowerEnabled and "ON" or "OFF"
        local text = string.format("Trainer: %s | Mode: %s | Style: %s | AutoPower: %s | Target: %s | Profile: %s",
            tostring(Settings.Enabled) == "true" and "ON" or "OFF", modeText, Settings.CurrentStyle, autoPowerStatus, tgtName, CurrentProfileName)
        statusLabel.Text = text
    end

    -- Update Keys Label
    if keysLabel then
        keysLabel.Text = "[ICE HUB V2] KEYBINDS:\n" ..
                            "[A] Toggle Trainer Enabled\n" ..
                            "[G] Lock Closest Target\n" ..
                            "[V] Unlock Target\n" ..
                            "[F] Toggle AutoLock Target\n" ..
                            "[Z] Cycle Throw Style\n" ..
                            "[Shift + Z] Cycle Profiles\n" .. -- Added new keybind info
                            "[U] Toggle Beam Visualization\n" ..
                            "[J] Toggle Arc Visualization\n" ..
                            "[P] Toggle Auto Power Mode\n" ..
                            "[L] Toggle Receiver Lead Spot\n" ..
                            "[O] Toggle Manual Mode (Lead Spot Only)\n" ..
                            "[NUM +/-] Adjust QB Release Delay\n" ..
                            "[R] Reset All Settings to Default"
    end
end

-- ====================================================================================================
-- MAIN CLIENT SCRIPT LOGIC
-- ====================================================================================================

-- Input Debounce table
local Debounce = {}
local DEBOUNCE_TIME = 0.2 -- seconds

-- Function to check and set debounce for a key
local function IsDebounced(key)
    local currentTime = os.clock()
    if not Debounce[key] or (currentTime - Debounce[key]) > DEBOUNCE_TIME then
        Debounce[key] = currentTime
        return false
    end
    return true
end

-- Call GUI creation once at the start
UIManager.CreateMainGUI()
UIManager.UpdateGUI() -- Initial GUI update to reflect loaded settings

-- Main Render Loop
RunService.RenderStepped:Connect(function()
    -- Main visibility check
    if not RuntimeState.LockTarget or not RuntimeState.LockTarget.Character or not RuntimeState.LockTarget.Character:FindFirstChild("HumanoidRootPart") or not Settings.Enabled then
        UIManager.HideBeam()
        UIManager.HideArc()
        UIManager.HideLanding()
        UIManager.HideLeadSpot()
        if dangerLabel then dangerLabel.Text = "" end
        if mainFrame then mainFrame.Visible = false end
        return
    end

    -- Ensure main GUI is visible if enabled and target locked
    if mainFrame then
        mainFrame.Visible = true
    end

    local targetHrp = RuntimeState.LockTarget.Character.HumanoidRootPart
    local playerHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not playerHrp then return end

    local originPos = Camera.CFrame.Position

    -- Receiver Prediction
    local targetInitialPos = targetHrp.Position
    local targetCurrentVel = targetHrp.AssemblyLinearVelocity
    local predictedTargetPosForThrow, predictedTargetVelForThrow = ReceiverPrediction.PredictReceiverPosition(
        targetHrp,
        Settings.ReceiverPredictionLookAheadTime
    )

    local currentThrowStyle = Settings.ThrowStyles[Settings.CurrentStyle]
    local basePower = currentThrowStyle.BasePower
    local verticalBias = currentThrowStyle.VertBias

    -- Auto Power Scaling by Target Distance
    local distanceToTarget = (predictedTargetPosForThrow - originPos).Magnitude
    if Settings.AutoPowerEnabled then
        local scaleFactor = math.min(1.0, math.max(Settings.MinPowerScaleFactor, distanceToTarget / Settings.MaxDistancePowerScale))
        basePower = basePower * scaleFactor
    end

    -- Calculate Throw Velocity, Time to Target, and Landing Position
    local throwVelocity, timeToTarget, estimatedLandingPos = TrajectoryMath.GetThrowVelocityAndTrajectory(
        originPos,
        predictedTargetPosForThrow,
        predictedTargetVelForThrow,
        basePower,
        verticalBias,
        Settings.Gravity,
        Settings.QBReleaseDelay
    )

    -- VISUALIZATIONS (Conditional based on Manual Mode)
    local displayBeam = Settings.BeamEnabled and not Settings.ManualModeEnabled
    local displayArc = Settings.ArcEnabled and not Settings.ManualModeEnabled
    local displayLanding = not Settings.ManualModeEnabled
    local displayDangerCheck = Settings.DangerCheck and not Settings.ManualModeEnabled

    if displayBeam then
        UIManager.DrawBeam(originPos, estimatedLandingPos)
    else
        UIManager.HideBeam()
    end

    if displayArc then
        UIManager.DrawArc(originPos, throwVelocity, Settings.Gravity, distanceToTarget)
    else
        UIManager.HideArc()
    end

    if displayLanding then
        UIManager.DrawLanding(estimatedLandingPos)
    else
        UIManager.HideLanding()
    end

    -- Lead Spot (forced ON in Manual Mode)
    if Settings.LeadSpotEnabled or Settings.ManualModeEnabled then
        local trueLeadSpot = targetHrp.Position + targetHrp.AssemblyLinearVelocity * (timeToTarget + Settings.QBReleaseDelay)
        UIManager.DrawLeadSpot(trueLeadSpot)
    else
        UIManager.HideLeadSpot()
    end

    -- Defender intercept danger check (Conditional based on Manual Mode)
    local danger = false
    if displayDangerCheck then
        local ballTrajectoryPoints = {}
        local currentBallPos = originPos
        local currentBallVel = throwVelocity
        local gravityVector = Vector3.new(0, -Settings.Gravity, 0)
        local simulationTimeStep = 0.05
        local maxSimTime = timeToTarget * 1.5 + 1 -- Simulate a bit longer than exact timeToTarget

        for t = 0, maxSimTime, simulationTimeStep do
            currentBallPos = currentBallPos + currentBallVel * simulationTimeStep + 0.5 * gravityVector * (simulationTimeStep^2)
            currentBallVel = currentBallVel + gravityVector * simulationTimeStep
            table.insert(ballTrajectoryPoints, {pos = currentBallPos, time = t})
            if currentBallPos.Y < Workspace.Terrain.MinY.Y - 5 then break end
        end

        danger = DefenderPrediction.CheckForDanger(ballTrajectoryPoints, originPos, throwVelocity)
    end

    -- Update Danger UI and provide audible feedback (only if not in Manual Mode)
    if dangerLabel then -- Ensure dangerLabel exists
        if displayDangerCheck then
            if danger then
                dangerLabel.Text = string.format("⚠️ DANGER: Interception Risk! Time: %.2fs", timeToTarget)
                dangerLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
                RuntimeState.LastSafePassTime = 0
            else
                dangerLabel.Text = string.format("✅ Pass is safe. Time: %.2fs", timeToTarget)
                dangerLabel.TextColor3 = Color3.fromRGB(50, 255, 50)
                if os.clock() - RuntimeState.LastSafePassTime > Settings.BeepCooldown then
                    safePassSound:Play() -- Use the preloaded sound
                    RuntimeState.LastSafePassTime = os.clock()
                end
            end
        else
            dangerLabel.Text = Settings.ManualModeEnabled and "Manual Mode Active (Lead Spot Only)" or ""
            dangerLabel.TextColor3 = Color3.fromRGB(255, 200, 0) -- Orange/yellow for manual mode info
        end
    end
end)

-- KEYBINDS (Still available for "power users" or for quick toggling)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    local key = input.KeyCode

    if IsDebounced(key) then return end -- Debounce check

    if key == Enum.KeyCode.A then
        Settings.Enabled = not Settings.Enabled
        print("[ICE HUB V2] Pass Trainer: " .. tostring(Settings.Enabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.G then
        RuntimeState.LockTarget = ReceiverPrediction.GetClosestTarget()
        if RuntimeState.LockTarget then
            print("[ICE HUB V2] Locked: " .. RuntimeState.LockTarget.Name)
        else
            print("[ICE HUB V2] No target found.")
        end
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.V then
        RuntimeState.LockTarget = nil
        print("[ICE HUB V2] Target unlocked.")
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.F then
        Settings.AutoLock = not Settings.AutoLock
        print("[ICE HUB V2] AutoLock: " .. tostring(Settings.AutoLock))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.Z then
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
            -- Cycle Profiles (Shift+Z)
            local currentProfileIndex = table.find(RuntimeState.ProfileNamesCache, CurrentProfileName)
            local nextIndex = (currentProfileIndex % #RuntimeState.ProfileNamesCache) + 1
            LoadProfile(RuntimeState.ProfileNamesCache[nextIndex])
        else
            -- Cycle Throw Styles (Z)
            local styleNames = {}
            for name, _ in pairs(Settings.ThrowStyles) do
                table.insert(styleNames, name)
            end
            table.sort(styleNames)

            local currentIndex = table.find(styleNames, Settings.CurrentStyle)
            Settings.CurrentStyle = styleNames[(currentIndex % #styleNames) + 1]
            print("[ICE HUB V2] Throw Style: " .. Settings.CurrentStyle)
            SaveSettings()
            UIManager.UpdateGUI()
        end

    elseif key == Enum.KeyCode.U then
        Settings.BeamEnabled = not Settings.BeamEnabled
        print("[ICE HUB V2] Beam: " .. tostring(Settings.BeamEnabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.J then
        Settings.ArcEnabled = not Settings.ArcEnabled
        print("[ICE HUB V2] Arc: " .. tostring(Settings.ArcEnabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.P then
        Settings.AutoPowerEnabled = not Settings.AutoPowerEnabled
        print("[ICE HUB V2] Auto Power Mode: " .. tostring(Settings.AutoPowerEnabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.L then
        Settings.LeadSpotEnabled = not Settings.LeadSpotEnabled
        print("[ICE HUB V2] Lead Spot: " .. tostring(Settings.LeadSpotEnabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.O then
        Settings.ManualModeEnabled = not Settings.ManualModeEnabled
        print("[ICE HUB V2] Manual Mode: " .. tostring(Settings.ManualModeEnabled))
        SaveSettings()
        UIManager.UpdateGUI()

    elseif key == Enum.KeyCode.R then
        ResetSettings()
        UIManager.UpdateGUI() -- Ensure GUI reflects reset

    elseif key == Enum.KeyCode.KeypadPlus then
        Settings.QBReleaseDelay = math.min(0.5, Settings.QBReleaseDelay + 0.01)
        print(string.format("[ICE HUB V2] QB Release Delay: %.2fs", Settings.QBReleaseDelay))
        SaveSettings()
        UIManager.UpdateGUI()
    elseif key == Enum.KeyCode.KeypadMinus then
        Settings.QBReleaseDelay = math.max(0, Settings.QBReleaseDelay - 0.01)
        print(string.format("[ICE HUB V2] QB Release Delay: %.2fs", Settings.QBReleaseDelay))
        SaveSettings()
        UIManager.UpdateGUI()
    end
end)

print(string.format("[ICE HUB V2] Loaded! Version: %d. Use GUI or Keybinds [A]=Toggle Trainer [G]=Lock [V]=Unlock [F]=AutoLock [Z]=Style [Shift+Z]=Cycle Profiles [U]=Beam [J]=Arc [P]=Auto Power [L]=Lead Spot [O]=Manual Mode [R]=Reset Config (Num +/- for QB Delay)", Settings.Version))
