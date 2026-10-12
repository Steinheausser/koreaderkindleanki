--[[
Kindle: keep MTP (USB file transfer) working while KOReader is running.

koreader.sh SIGSTOPs volumd, because on USB Mass Storage Kindles plugging in USB unmounts the userstore
from under us. On MTP Kindles (tizen-mtp), volumd is what switches MTP on at plug-in, so with it stopped
a computer only ever sees a charging device.

MTP never unmounts the userstore, but while a computer has an MTP session open the system's FUSE proxy
(fsp, mounted at /mnt/us) answers *every* request with ESTALE. The KOReader.sh launcher works around that
by starting us in a private mount namespace where /mnt/us is a bind mount of the real filesystem
(/mnt/base-us), which fsp's lock doesn't affect. Only in that case is it safe to let volumd run again.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

if lfs.attributes("/etc/upstart/mtp.conf", "mode") ~= "file"
    or lfs.attributes("/etc/upstart/volumd.conf", "mode") ~= "file" then
    return -- not an MTP Kindle
end

-- Filesystem type of whatever is mounted at /mnt/us in *our* mount namespace (the last entry wins).
local function getMntUsFsType()
    local f = io.open("/proc/self/mountinfo", "r")
    if not f then return end
    local fstype
    for line in f:lines() do
        local mount_point, fs = line:match("^%S+ %S+ %S+ %S+ (%S+) .- %- (%S+) ")
        if mount_point == "/mnt/us" then
            fstype = fs
        end
    end
    f:close()
    return fstype
end

local fstype = getMntUsFsType()
if fstype == nil or fstype:match("^fuse") then
    logger.info("Kindle MTP: /mnt/us is", fstype, "(not started via the namespaced KOReader.sh), leaving volumd stopped")
    return
end

os.execute("killall -CONT volumd")
logger.info("Kindle MTP: /mnt/us is", fstype, "in our namespace, resumed volumd so MTP can start on USB plug-in")

-- fsp presents every file as 0777, so files copied over MTP (which land as 0664) were still executable through it.
-- On the raw filesystem they aren't: restore +x on plugin binaries and scripts (e.g., Syncthing's launcher).
local function isExecutableContent(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local magic = f:read(4) or ""
    f:close()
    return magic == "\127ELF" or magic:sub(1, 2) == "#!"
end

local function fixExecBits(dir)
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                fixExecBits(path)
            elseif attr and attr.mode == "file" and not attr.permissions:match("^..x") and isExecutableContent(path) then
                os.execute("chmod a+x '" .. path:gsub("'", "'\\''") .. "'")
                logger.info("Kindle MTP: restored exec bit on", path)
            end
        end
    end
end

fixExecBits("plugins")
