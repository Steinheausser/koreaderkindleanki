-- Render every card of a pack (question + answer) the way the reviewer does, into one tall PNG per side.
--   cd /mnt/us/koreader && ./luajit <this> <exchange folder> <out dir>
require("setupkoenv")
local Mupdf = require("ffi/mupdf")
local DrawContext = require("ffi/drawcontext")
local Blitbuffer = require("ffi/blitbuffer")
local rapidjson = require("rapidjson")
-- Same CSS pieces as HtmlBoxWidget (mupdf_css_fixes) + reviewer EXTRA_CSS
local src = io.open("frontend/ui/widget/htmlboxwidget.lua"):read("*a")
local fixes = src:match('local mupdf_css_fixes = %[%[(.-)%]%]') or ""
local reviewer = io.open(arg[3] .. "/ankireview_reviewer.lua"):read("*a")
local extra = reviewer:match('local EXTRA_CSS = %[%[(.-)%]%]')
local pack = assert(rapidjson.load(arg[1] .. "/pack/pack.json"))
local W, H, FONT = 1000, 420, 44 -- ~ Screen:scaleBySize(22) on a 300 dpi Basic
local out = Blitbuffer.new(W * 2 + 30, (H + 20) * #pack.cards, Blitbuffer.TYPE_BB8)
out:fill(Blitbuffer.COLOR_GRAY)
for i, c in ipairs(pack.cards) do
  for side, html in ipairs({ c.q, c.a }) do
    local doc = Mupdf.openDocumentFromText(string.format("<html><head><style>\n%s\n%s%s</style></head><body><div class=\"card\">%s</div></body></html>",
      fixes, pack.css[c.mid] or "", extra, (html:gsub("%<br ?/?%>", "&nbsp;<div></div>"))), "html", arg[1] .. "/pack/media")
    doc:layoutDocument(W, H, FONT)
    local page = doc:openPage(1)
    local bb = page:draw_new(DrawContext.new(), W, H, 0, 0)
    out:blitFrom(bb, (side - 1) * (W + 30), (i - 1) * (H + 20), 0, 0, W, H)
    page:close(); doc:close()
  end
end
out:writePNG(arg[2] .. "/cards.png")
print("rendered", #pack.cards)
