-- opencraft
local version = {
  ["major"] = 1,
  ["minor"] = 2,
  ["patch"] = 1
}

-- utility functions
function serialize(o, indent)
  local s = ""
  indent = indent or ""
  if type(o) == "number" then
    s = s .. indent .. tostring(o)
  elseif type(o) == "boolean" then
    s = s .. indent .. (o and "true" or "false")
  elseif type(o) == "string" then
    if o:find("\n") then
      s = s .. indent .. "[[\n" .. o:gsub("\"", "\\\"") .. "]]"
    else
      s = s .. indent .. string.format("%q", o)
    end
  elseif type(o) == "table" then
    s = s .. "{\n"
    for k,v in pairs(o) do
      if type(v) == "table" then
        s = s .. indent .. "  [" .. serialize(k) .. "] = " .. serialize(v, indent .. "  ") .. ",\n"
      else
        s = s .. indent .. "  [" .. serialize(k) .. "] = " .. serialize(v) .. ",\n"
      end
    end
    s = s .. indent .. "}"
  else
    s = s .. indent .. "nil"
    --error("cannot serialize a " .. type(o))
  end
  return s
end

function loadFile(fileName)
  local f = fs.open(fileName, "r")
  if f ~= nil then
    local data = f.readAll()
    f.close()
    return textutils.unserialize(data)
  end
end

function saveFile(fileName, data)
  local f = fs.open(fileName, "w")
  f.write(serialize(data))
  f.close()
end

-- setup

local recipes = loadFile("recipes.dat") or {}
local nameFix = loadFile("namefix.dat") or {
  ["sub"] = {},
  ["replace"] = {}
}
local useDmg = loadFile("usedmg.dat") or {}

local sideToDir = loadFile("directions.dat")
if sideToDir == nil then
  sideToDir = {
    ["top"] = "down",
    ["bottom"] = "up",
    ["front"] = "north",
    ["back"] = "south",
    ["self"] = "east"
  }
  saveFile("directions.dat", sideToDir)
end

function fixName(name)
  if nameFix.sub[name] then
    return nameFix.sub[name]
  else
    for find, replace in pairs(nameFix.replace) do
      name = name:gsub(find, replace)
    end
    return name
  end
end

local inv = {}
local invs = {}
local stacks = {}
local self
local narcissistic = true

--[[ example entry from getAllStacks
id:17
name:Oak Wood
rawName:tile.log.oak
dmg:0
maxSize:64
ench:table: ffffffff
qty:64
--]]

function findInventories()
  invs = {}
  for i, name in ipairs(peripheral.getNames()) do
    local chest = peripheral.wrap(name)
    if chest.getAllStacks ~= nil then
      if peripheral.getType(name) == "turtle" then
        self = chest
      elseif (name == "left" or name == "right") and peripheral.getType(name) == "container_chest" then
        self = chest
        narcissistic = false
      else
        invs[name] = chest
      end
    elseif chest.getAvailableItems ~= nil then
      invs[name] = chest
      -- wrap AE functions
      chest.pullItem = function (direction, from_turtle_slot, count, to_chest_slot)
        return chest.insertItem(from_turtle_slot, count, direction)
      end
      chest.getAllStacks = chest.getAvailableItems
    end
  end
  if self == nil then
    error("Need narcissistic turtle or wooden single chest on left")
  end
end

function fixItemStacks(stacks)
  -- fix raw name for items know to need dmg value
  if stacks.rawName then
    if inv[stacks.rawName] and inv[stacks.rawName].useDmg then
      stacks.rawName = stacks.rawName .. "@" .. stacks.dmg
    end
  else
    for slot, item in pairs(stacks) do
      if inv[item.rawName] and inv[item.rawName].useDmg then
        item.rawName = item.rawName .. "@" .. item.dmg
      end
    end
  end
  return stacks
end

function getTurtleStacks(getSlot)
  if narcissistic then
    if getSlot == nil then
      return fixItemStacks(self.getAllStacks())
    else
      return fixItemStacks(self.getStackInSlot(getSlot))
    end
  else
    if getSlot == nil then
      for slot = 1, 16 do
        self.pullItem(sideToDir["self"], slot, 64, slot)
      end
      local items = self.getAllStacks()
      for slot = 1, 16 do
        self.pushItem(sideToDir["self"], slot, 64, slot)
      end
      return fixItemStacks(items)
    else
      self.pullItem(sideToDir["self"], getSlot, 64, getSlot)
      local item = self.getStackInSlot(getSlot)
      self.pushItem(sideToDir["self"], getSlot, 64, getSlot)
      return fixItemStacks(item)
    end
  end  
end

function unloadTurtle()
  local items = getTurtleStacks()
  for slot, item in pairs(items) do
    local sides = {}
    local side = getHighSide(item.rawName)
    if side ~= nil then
      table.insert(sides, side)
    end
    for side, chest in pairs(invs) do
      if side ~= sides[1] then
        table.insert(sides, side)
      end
    end
    for _, side in ipairs(sides) do
      local chest = invs[side]
      local chestItems = stacks[side]
      local unload = item.qty
      for chestSlot, chestItem in pairs(chestItems) do
        if chestItem.rawName == item.rawName then
          local moved = chest.pullItem(sideToDir[side], slot, unload, chestSlot)
          unload = unload - moved
          chestItem.qty = chestItem.qty + moved
          local invItem = inv[item.rawName]
          invItem.total = invItem.total + moved
          for i, invItemStack in ipairs(invItem) do
            if invItemStack.slot == chestSlot then
              invItemStack.qty = invItemStack.qty + moved
            end
          end
          if unload <= 0 then
            break
          end
        end
      end
      if unload > 0 then
        if chest.getInventorySize then
          for freeSlot = 1, chest.getInventorySize() do
            if chestItems[freeSlot] == nil then
              chest.pullItem(sideToDir[side], slot, unload, freeSlot)
              local invItem = inv[item.rawName]
              if invItem == nil then
                invItem = {
                  ["total"] = item.qty,
                  ["name"] = fixName(item.name),
                  ["rawName"] = item.rawName,
                  ["id"] = item.id,
                  ["maxSize"] = item.maxSize,
                }
                inv[item.rawName] = invItem
              end
              invItem.total = invItem.total + item.qty
              table.insert(invItem, {
                ["qty"] = item.qty,
                ["name"] = fixName(item.name),
                ["rawName"] = item.rawName,
                ["id"] = item.id,
                ["maxSize"] = item.maxSize,
                ["dmg"] = item.dmg,
                ["side"] = side,
                ["slot"] = freeSlot
              })
              chestItems[freeSlot] = {
                ["qty"] = item.qty,
                ["name"] = fixName(item.name),
                ["rawName"] = item.rawName,
                ["id"] = item.id,
                ["maxSize"] = item.maxSize,
                ["dmg"] = item.dmg,
              }
              break
            end
          end
        else
          -- AE support
          chest.pullItem(sideToDir[side], slot, unload, 0)
        end
      end
    end
  end
  takeInventory()
end

function detectDmg(item)
  if item.rawName:find("@@") == nil then
    local invItem = inv[item.rawName]
    -- detect items that need to use dmg value
    if invItem ~= nil and
        invItem.rawName == item.rawName and 
        (invItem.dmg ~= item.dmg or  item.id ~= item.id) and 
        invItem.name ~= item.name then
      -- fix current inv
      invItem.rawName = invItem.rawName .. "@" .. invItem.dmg
      inv[invItem.rawName] = invItem
      -- set normal rawName with useDmg flag
      inv[item.rawName] = {useDmg = true}
      -- fix recipes
      if recipes[item.rawName] then
        local recipe = recipes[item.rawName]
        recipe.rawName = recipe.rawName .. "@" .. recipe.dmg
        recipes[recipe.rawName] = recipe
        recipes[item.rawName] = nil
        saveFile("recipes.dat", recipes)
      end
      -- add rawName to useDmg file
      useDmg[item.rawName] = true
      saveFile("usedmg.dat", useDmg)
      -- fix new item to be put in inventory
      item.rawName = item.rawName .. "@" .. item.dmg
    end
  end
  return item
end

function takeInventory()
  inv = {}
  stacks = {}
  -- load rawNames that need dmg value to be unique
  for rawName, _ in pairs(useDmg) do
    inv[rawName] = {useDmg = true}
  end
  -- load recipes
  for rawName, recipe in pairs(recipes) do
    local item = {
      ["rawName"] = recipe.rawName,
      ["name"] = fixName(recipe.name),
      ["id"] = recipe.id,
      ["dmg"] = recipe.dmg,
      ["maxSize"] = recipe.maxSize,
      ["total"] = 0,
    }
    if item.name ~= recipe.name then
      item.origName = recipe.name
    end
    inv[rawName] = item
  end
  -- load items from chests
  for side, chest in pairs(invs) do
    stacks[side] = fixItemStacks(chest.getAllStacks())
    for slot, item in pairs(stacks[side]) do
      item = detectDmg(item)
      local invItem = inv[item.rawName]
      if invItem ~= nil then
        invItem.total = invItem.total + item.qty
        table.insert(invItem, {
          ["qty"] = item.qty,
          ["name"] = fixName(item.name),
          ["rawName"] = item.rawName,
          ["id"] = item.id,
          ["dmg"] = item.dmg,
          ["maxSize"] = item.maxSize,
          ["side"] = side,
          ["slot"] = slot
        })
      else
        invItem = {
          ["total"] = item.qty,
          ["name"] = fixName(item.name),
          ["rawName"] = item.rawName,
          ["id"] = item.id,
          ["dmg"] = item.dmg,
          ["maxSize"] = item.maxSize,
          [1] = {
            ["qty"] = item.qty,
            ["name"] = fixName(item.name),
            ["rawName"] = item.rawName,
            ["id"] = item.id,
            ["maxSize"] = item.maxSize,
            ["dmg"] = item.dmg,
            ["side"] = side,
            ["slot"] = slot
          }
        }
        if invItem.name ~= item.name then
          invItem.origName = item.name
        end
        inv[item.rawName] = invItem
      end
    end
  end
end

function search(name)
  name = name:lower()
  name = name:gsub('[%-%.%+%[%]%(%)%$%^%%%?%*]','%%%1'):gsub('%z','%%z')
  local results = {}
  for rawName, invItem in pairs(inv) do
    if invItem.name and (name == "" or string.match(invItem.name:lower(), name) or string.match(tostring(invItem.id), name)) then
      table.insert(results, invItem)
    end
  end
  return results
end

function orderBy(lookup, prop, descending, default)
  lookup = lookup or inv
  if descending == nil then descending = false end
  if default == nil then default = 0 end
  return function (a, b)
    local av, bv
    if prop then
      av = lookup[a] and lookup[a][prop] or default
      bv = lookup[b] and lookup[b][prop] or default
    else
      av = lookup[a] or default
      bv = lookup[b] or default
    end
    return (av > bv) == descending
  end
end

function filterBy(list, display)
  local fids = {}
  for i, invItem in ipairs(list) do
    if display == 1 or
        ((display == 3 or display == 4) and recipes[invItem.rawName] ~= nil) or
        ((display == 2 or display == 4) and inv[invItem.rawName] ~= nil and inv[invItem.rawName].total > 0)
        then
      table.insert(fids, invItem)
    end
  end
  return fids
end

function formatNumber(n)
  if n < 10 then
    return "   "..tostring(n)
  elseif n < 100 then
    return "  "..tostring(n)
  elseif n < 1000 then
    return " "..tostring(n)
  elseif n < 10000 then
    return tostring(n)
  elseif n < 100000 then
    return " "..tostring(math.floor(n / 1000)).."K"
  elseif n < 1000000 then
    return tostring(math.floor(n / 1000)).."K"
  else
    return tostring(math.floor(n / 100000) / 10).."M"
  end
end

os.loadAPI("apis/panel")

local panelSearch = panel.new{y=-1, h=-1,
                              textColor=colors.black,
                              backgroundColor=colors.white,
                              blink=true}
local panelStatus = panel.new{y=1, h=2,
                              textColor=colors.black,
                              backgroundColor=colors.white}
local panelItems = panel.new{y=3, h=-4,
                             textColor=colors.white,
                             backgroundColor=colors.black}
panelItems.redirect()
local width, height = term.getSize()
local status = {
 display = 4,
 displayText = {" all  ", "stored", "craft ", " both "},
 order = 1,
 orderText = {"count", "name ", " id  ", "stack"},
 orderDir = 1,
 orderDirText = {"desc", "asc "},
 selected = 1,
 focus = false,
 searchTotal = 0,
 idViewed = 1,
 idSelected = 1,
 pageSize = height,
}

function getHighSide(rawName)
  local sideCount = {}
  local highCount = 0
  local highSide
  if inv[rawName] then
    for i, item in ipairs(inv[rawName]) do
      if item.side then
        if sideCount[item.side] then
          sideCount[item.side] = sideCount[item.side] + item.qty
        else
          sideCount[item.side] = item.qty
        end
        if sideCount[item.side] > highCount then
          highCount = sideCount[item.side]
          highSide = item.side
        end
      end
    end
  end
  return highSide
end

function changeId(up)
  panelItems.redirect()
  term.setCursorPos(5, status.idSelected - status.idViewed + 1)
  term.write(" ")
  if status.idSelected > 1 and up then
    status.idSelected = status.idSelected - 1
  elseif status.idSelected < status.searchTotal and not up then
    status.idSelected = status.idSelected + 1
  end
  if status.idSelected < status.idViewed then
    status.idViewed = status.idSelected
    listItems()
  elseif status.idSelected > (status.idViewed + status.pageSize - 1) then
    status.idViewed = math.min(status.searchTotal - status.pageSize + 1, status.idSelected)
    listItems()
  end
  term.setCursorPos(5, status.idSelected - status.idViewed + 1)
  term.write(">")
  showStatus()
end

function searchItems(text)
  local sids = search(text:lower())
  if sids then
    status.idSelected = 1
    status.idViewed = 1
    sids = filterBy(sids, status.display)
    if status.order == 1 then
      table.sort(sids, function(a,b) return (a.total > b.total) == (status.orderDir == 1) end)
    elseif status.order == 2 then
      table.sort(sids, function(a,b) return (a.name > b.name) == (status.orderDir == 1) end)
    elseif status.order == 3 then
      table.sort(sids, function(a,b) return (a.id > b.id) == (status.orderDir == 1) end)
    elseif status.order == 4 then
      table.sort(sids, function(a,b) return (a.maxSize > b.maxSize) == (status.orderDir == 1) end)
    end
    status.inv = sids
    status.searchTotal = #sids
  else
    status.inv = nil
  end
  listItems()
  showStatus()
end

function listItems()
  panelItems.redirect()
  if status.inv then
    local width, height = term.getSize()
    term.clear()
    for i = status.idViewed, status.idViewed + math.min(#status.inv, status.pageSize) - 1 do
      local item = status.inv[i]
      term.setCursorPos(1, i - status.idViewed + 1)
      write(formatNumber(item.total))
      if status.idSelected == i then
        write(">")
      else
        write(" ")
      end
      write(item.name:sub(1, 33))
    end
  else
    term.clear()
    status.searchTotal = 0
    status.idSelected = 0
  end
end

function rotate(n, max, decrement)
  if decrement then
    n = n - 1
    if n < 1 then n = max end
  else
    n = n + 1
    if n > max then n = 1 end
  end
  return n
end

function changeSelected(forward)
  status.selected = rotate(status.selected, 3, forward)
  showStatus()
end

function changeOption(up)
  if status.selected == 1 then
    status.display = rotate(status.display, #status.displayText, up)
  elseif status.selected == 2 then
    status.order = rotate(status.order, #status.orderText, up)
  elseif status.selected == 3 then
    status.orderDir = rotate(status.orderDir, #status.orderDirText, up)
  end
  showStatus()
end

function showStatus()
  panelStatus:redirect()
  term.setCursorPos(1, 1)
  write("F1-Help F5-Refresh F6-Teach                ")
  local v = string.format("v%d.%d.%d", version.major, version.minor, version.patch)
  term.setCursorPos(40-v:len(), 1)
  write(string.format("v%d.%d.%d", version.major, version.minor, version.patch))
  term.setCursorPos(1, 2)
  for i = 1, 3 do
    if status.focus and status.selected == i then
      --term.setTextColor(colors.white)
      write("<")
    else
      --term.setTextColor(colors.black)
      write(" ")
    end
    if i == 1 then
      write(status.displayText[status.display])
    elseif i == 2 then
      write(status.orderText[status.order])
    elseif i == 3 then
      write(status.orderDirText[status.orderDir])
    end
    if status.focus and status.selected == i then
      write(">")
    else
      write(" ")
    end
  end
  term.setTextColor(colors.black)
  write(" item")
  write(formatNumber(status.idSelected))
  write(" of ")
  write(formatNumber(status.searchTotal))
  panelSearch.redirect()
end

function make(rawName, amount, makeStack, used)
  local invItem = inv[rawName]
  makeStack = makeStack or {}
  used = used or {}
  makeStack[rawName] = true
  amount = amount or 1
  if not invItem then
    return false
  end
  print("making "..tostring(amount).." "..invItem.name)
  local recipe = recipes[rawName]
  if not recipe then
    print("can't make "..invItem.name..", no recipe")
    return false
  end
  amount = math.ceil(amount / recipe.yield)
  local mat = {}
  for loc, makeRawName in ipairs(recipe) do
    local row = math.floor((loc - 1) / recipe.size.cols)
    local col = (loc - 1) % recipe.size.cols
    local slot = row * 4 + col + 2
    if makeRawName ~= "" then
      if mat[makeRawName] then
        table.insert(mat[makeRawName], slot)
      else
        mat[makeRawName] = {slot}
      end
    end
  end
  local maxStack = invItem.maxSize
  for makeRawName, slots in pairs(mat) do
    local needed = verify(makeRawName, amount * #slots, used)
    if used[makeRawName] then
      used[makeRawName] = used[makeRawName] + (amount * #slots - needed)
    else
      used[makeRawName] = amount * #slots - needed
    end
    if needed > 0 then
      if makeStack[makeRawName] or not make(makeRawName, needed, makeStack, used) then
        if inv[makeRawName] then
          print("can't make "..invItem.name..", need "..needed.." "..inv[makeRawName].name)
        else
          print("can't make "..invItem.name..", need "..needed.." "..makeRawName)
        end
        return false
      end
    end
    if type(makeRawName) == "number" then
      maxStack = math.min(inv[makeRawName].maxSize, maxStack)
    elseif made ~= nil then
      maxStack = math.min(inv[made].maxSize, maxStack)
    end
  end
  unloadTurtle()
  while amount > 0 do
    local currAmount = math.min(amount, maxStack)
    for makeRawName, slots in pairs(mat) do
      request(makeRawName, currAmount, slots)
    end
    turtle.craft()
    local count = turtle.getItemCount(1)
    unloadTurtle()
    --idPutBest(rawName, count)
    amount = amount - currAmount
  end
  return true
end

function verify(rawName, amount, used)
  used = used or {}
  local needed = amount
  local verifyRawNames
  verifyRawNames = {rawName}
  for _, verifyRawName in ipairs(verifyRawNames) do
    if inv[verifyRawName] then
      local total = inv[verifyRawName].total
      if used[verifyRawName] then
        total = total - used[verifyRawName]
      end
      needed = needed - total
    end
  end
  return math.max(0, needed)
end

function request(rawName, amount, slots)
  local total = amount * #slots
  local needed = verify(rawName, total)
  if needed > 0 then
    if type(rawName) == "string" then
      print("need more "..rawName)
    else
      print("need more "..ids[rawName].name)
    end
    return false
  else
    -- fill 1 slot at a time
    for i, slot in ipairs(slots) do
      --consolidate(rawName)
      local pushed = amount
      for i, item in ipairs(inv[rawName]) do
        if item.qty > 0 then
          local moved
          if invs[item.side].pushItem then
            moved = invs[item.side].pushItem(sideToDir[item.side], item.slot, math.min(pushed, item.qty), slot)
          elseif invs[item.side].extractItem then
            moved = invs[item.side].extractItem({id=item.id, dmg=item.dmg, qty=math.min(pushed, item.qty)}, sideToDir[item.side])
            self.swapStacks(1, slot)
          end
          item.qty = item.qty - moved
          inv[rawName].total = inv[rawName].total - moved
          pushed = pushed - moved
          if pushed <= 0 then
            break
          end
        end
      end
    end
    return true
  end
end

function teachRecipe()
  panelItems.redirect()
  term.clear()
  if not turtle.craft(0) then
    print("invalid recipe")
    return nil
  end
  local items = getTurtleStacks()
  slotRows = {1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4}
  slotCols = {1,2,3,4,1,2,3,4,1,2,3,4,1,2,3,4}
  local startRow = 4
  local endRow = 1
  local startCol = 4
  local endCol = 1
  for slot, item in pairs(items) do
    startRow = math.min(slotRows[slot], startRow)
    endRow = math.max(slotRows[slot], endRow)
    startCol = math.min(slotCols[slot], startCol)
    endCol = math.max(slotCols[slot], endCol)
  end
  local rows = endRow - startRow + 1
  local cols = endCol - startCol + 1
  local recipe = {}
  for row = startRow, endRow do
    for col = startCol, endCol do
      local index = (row - 1) * 4 + col
      if items[index] then
        if items[index].qty > 1 then
          print("invalid recipe, too many items")
          return nil
        else
          table.insert(recipe, items[index].rawName)
        end
      else
        table.insert(recipe, "")
      end
    end
  end
  turtle.craft()
  local item = getTurtleStacks(1)
  if item then
    item = detectDmg(item)
    recipe.yield = item.qty
    recipe.size = {["rows"] = rows, ["cols"] = cols}
    recipe.rawName = item.rawName
    recipe.name = item.name
    recipe.id = item.id
    recipe.dmg = item.dmg
    recipe.maxSize = item.maxSize
    recipes[recipe.rawName] = recipe
    saveFile("recipes.dat", recipes)
    print("new recipe for "..item.name)
  else
    print("invalid recipe")
  end
  print("press [Enter] to continue...")
  read()
end

function main()
  turtle.select(1)
  showStatus()
  local text = ""
  panelItems.redirect()
  term.clear()
  searchItems("")
  term.setCursorBlink(true)
  term.setCursorPos(1, 1)
  while true do
    panelSearch.redirect()
    term.clear()
    term.setCursorPos(1, 1)
    term.write(text)
    local width = term.getSize()
    local event, code = os.pullEvent()
    if event == "char" then
      text = text .. code
      term.setCursorPos(#text, 1)
      write(code)
      searchItems(text)
    elseif event == "key" then
      if code == keys.backspace then
        term.setCursorPos(#text, 1)
        write(" ")
        term.setCursorPos(#text, 1)
        text = text:sub(1, #text - 1)
        searchItems(text)
      elseif code == keys.delete then
        term.setCursorPos(1, 1)
        write(string.rep(" ", width))
        term.setCursorPos(1, 1)
        text = ""
        searchItems(text)
      elseif code == keys.f1 then
        panelItems.redirect()
        term.clear()
        term.setCursorPos(1, 1)
-------------------|-------------------
        write([[
                Layout

The top bar is the status. It displays
the hotkeys and the current search
options. The bottom bar is the search
box. It displays the current search and
is used for other prompts. The center
is the search results and info.

      Press [ENTER] to continue.]])
        read()
-------------------|-------------------
        write([[
               Searching

Start typing to search for all items or
recipes in the system. Use [BACKSPACE]
to delete one character and [DELETE] to
clear the search. Use [F5] to refresh
the counts of items in inventory.


      Press [ENTER] to continue.]])
        read()
-------------------|-------------------
        write([[
            Search Options

Use [TAB] to change the search options.
The option you are changing has
brackets. Use [LEFT] and [RIGHT] to
change options. Use [UP] and [DOWN] to
change option settings.


      Press [ENTER] to continue.]])
        read()
-------------------|-------------------
        write([[
               Requesting

An arrow shows the selected item in the
search results. Use the [UP] and [DOWN]
keys to select an item. Use [ENTER] to
request an item. If there are zero then
the system will craft them.


      Press [ENTER] to continue.]])
        read()
-------------------|-------------------
        write([[
               Teaching

Place items in the grid as you would in
a crafting table. Use [F6] to craft the
item and teach the system the recipe.
When requesting items the system will
craft all prerequisite items if missing
if in knows the recipe.

      Press [ENTER] to continue.]])
        read()
-------------------|-------------------
        searchItems(text)
      elseif code == keys.f5 then
        unloadTurtle()
        findInventories()
        takeInventory()
        searchItems(text)
      elseif code == keys.f6 then
        teachRecipe()
        --unloadTurtle()
        takeInventory()
        searchItems(text)
      elseif code == keys.left then
        if status.focus then
          changeSelected(true)
        end
      elseif code == keys.right then
        if status.focus then
          changeSelected(false)
        end
      elseif code == keys.up then
        if status.focus then
          changeOption(true)
          searchItems(text)
        else
          changeId(true)
        end
      elseif code == keys.down then
        if status.focus then
          changeOption(false)
          searchItems(text)
        else
          changeId(false)
        end
      elseif code == keys.tab then
        status.focus = not status.focus
        showStatus()
      elseif code == keys.pageUp then
      elseif code == keys.pageDown then
      elseif code == keys.f4 then
        if status.inv ~= nil and status.idSelected ~= nil and status.inv[status.idSelected] ~= nil then
          panelSearch.redirect()
          term.clear()
          term.setCursorPos(1, 1)
          write("New Name: ")
          newName = read()
          if newName ~= "" then
            local item = status.inv[status.idSelected]
            local oldName = item.origName or item.name
            nameFix.sub[oldName] = newName
            saveFile("namefix.dat", nameFix)
            takeInventory()
          end
          searchItems(text)
        end
      elseif code == keys.enter then
        if status.inv ~= nil and status.idSelected ~= nil and status.inv[status.idSelected] ~= nil then
          local rawName = status.inv[status.idSelected].rawName
          local count = 64
          if inv[rawName] == nil or inv[rawName].total == nil or inv[rawName].total <= 0 then
            panelSearch.redirect()
            term.clear()
            term.setCursorPos(1, 1)
            write("How many? ")
            count = tonumber(read())
            count = count or 1
            if count then
              takeInventory()
              panelItems.redirect()
              term.clear()
              if not make(rawName, count) then
                print("press [Enter] to continue...")
                read()
              else
                takeInventory()
              end
            end
          end
          if inv[rawName] ~= nil and inv[rawName].total > 0 then
            local selfInv = getTurtleStacks()
            local freeSlot = 0
            for i = 1, 16 do
              if selfInv[i] == nil then
                freeSlot = i
                break
              end
            end
            if freeSlot > 0 then
              request(rawName, math.min(count, inv[rawName].total), {freeSlot})
            end
          end
          listItems(text)
        end
      end
    end
  end
  term.restore()
  term.clear()
end

findInventories()
takeInventory()
unloadTurtle()
main()
