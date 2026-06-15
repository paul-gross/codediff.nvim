-- Regression test for issue #1: ]f/[f navigation slows progressively over a
-- session because semantic-token virtual documents were opened on the language
-- server (textDocument/didOpen) on every render but never closed during
-- navigation, leaving an unbounded, ever-growing set of open documents.
--
-- This test drives a multi-file explorer diff with a fake language server that
-- advertises semantic tokens, cycles next_file many times, and asserts that the
-- server's open-document set stays bounded (didOpen is balanced by didClose) —
-- i.e. resources released on each hop do not grow with cumulative usage.

local h = dofile("tests/helpers.lua")

-- Install a fake LSP client that advertises semantic tokens and tracks its
-- open-document set the way a real language server would. Overrides
-- vim.lsp.get_clients so codediff's semantic_tokens + cleanup paths see it.
local function install_fake_lsp()
  _G.__probe_open_uris = {}
  _G.__probe_didopen = 0
  _G.__probe_didclose = 0
  _G.__probe_open_count = function()
    local n = 0
    for _ in pairs(_G.__probe_open_uris) do
      n = n + 1
    end
    return n
  end

  local client = {
    name = "fake-lsp",
    offset_encoding = "utf-16",
    server_capabilities = {
      semanticTokensProvider = { legend = { tokenTypes = {}, tokenModifiers = {} } },
    },
  }
  function client.notify(_, method, params)
    if method == "textDocument/didOpen" then
      _G.__probe_open_uris[params.textDocument.uri] = true
      _G.__probe_didopen = _G.__probe_didopen + 1
    elseif method == "textDocument/didClose" then
      _G.__probe_open_uris[params.textDocument.uri] = nil
      _G.__probe_didclose = _G.__probe_didclose + 1
    end
    return true
  end
  function client.request(_, _method, _params, handler)
    if handler then
      vim.schedule(function()
        handler(nil, { data = {} })
      end)
    end
    return true, 1
  end

  vim.lsp.get_clients = function()
    return { client }
  end
end

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, { nargs = "*", bang = true })
end

describe("issue #1: semantic-token document leak on file navigation", function()
  local temp_dir, original_cwd
  local saved_get_clients

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side", cycle_next_file = true } })
    setup_command()
    saved_get_clients = vim.lsp.get_clients
    original_cwd = vim.fn.getcwd()
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    vim.fn.chdir(temp_dir)

    h.git_cmd(temp_dir, "init")
    h.git_cmd(temp_dir, "branch -m main")
    h.git_cmd(temp_dir, 'config user.email "test@example.com"')
    h.git_cmd(temp_dir, 'config user.name "Test User"')

    -- Several committed files, all then modified -> multi-file diff to cycle.
    for i = 1, 6 do
      vim.fn.writefile({ "a", "b", "c", "d" }, temp_dir .. "/f" .. i .. ".txt")
      h.git_cmd(temp_dir, "add f" .. i .. ".txt")
    end
    h.git_cmd(temp_dir, 'commit -m "init"')
    for i = 1, 6 do
      vim.fn.writefile({ "a", "B" .. i, "c", "d", "e" }, temp_dir .. "/f" .. i .. ".txt")
    end
    -- Stage half so navigation visits virtual-vs-virtual (staged) AND
    -- real-vs-virtual (unstaged) diffs, both of which run semantic tokens.
    for i = 1, 3 do
      h.git_cmd(temp_dir, "add f" .. i .. ".txt")
    end
  end)

  after_each(function()
    vim.lsp.get_clients = saved_get_clients
    require("codediff.ui.lifecycle").cleanup_all()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  it("keeps the server's open-document set bounded across many ]f hops", function()
    local lifecycle = require("codediff.ui.lifecycle")
    vim.wait(200)
    lifecycle.cleanup_all()

    install_fake_lsp()

    vim.cmd("edit " .. temp_dir .. "/f1.txt")
    vim.cmd("CodeDiff")

    local ready = vim.wait(6000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local e = lifecycle.get_explorer(tp)
        if e and e.current_file_path ~= nil then
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(ready, "explorer should open")

    local nav = require("codediff.ui.view.navigation")

    -- The diff has at most 6 distinct files, each with at most 2 virtual sides,
    -- so the live open-document set can never legitimately exceed that. The leak
    -- (didClose never sent during navigation) would push it far past this bound.
    local OPEN_BOUND = 12

    local N = 80
    local max_open = 0
    for _ = 1, N do
      nav.next_file()
      vim.wait(40) -- let async virtual-file load + render settle
      local open = _G.__probe_open_count()
      if open > max_open then
        max_open = open
      end
    end

    -- A leak shows up as didOpen growing with N while didClose stays flat.
    assert.is_true(_G.__probe_didopen > 0, "semantic tokens should have opened virtual documents")
    assert.is_true(
      max_open <= OPEN_BOUND,
      string.format("open-document set must stay bounded; saw %d open (didOpen=%d didClose=%d)", max_open, _G.__probe_didopen, _G.__probe_didclose)
    )

    -- Repo-size-independent guard: each hop that opens a document must close the
    -- one it navigated away from, so at most OPEN_BOUND documents are ever left
    -- open. The pre-fix leak sent zero didClose during navigation, so didOpen
    -- (which grows with N) would outrun didClose without bound.
    assert.is_true(
      _G.__probe_didopen - _G.__probe_didclose <= OPEN_BOUND,
      string.format("didClose must track didOpen during navigation (didOpen=%d didClose=%d)", _G.__probe_didopen, _G.__probe_didclose)
    )

    -- After closing the diff entirely, every opened document must be closed.
    lifecycle.cleanup_all()
    vim.wait(200)
    assert.are.equal(
      0,
      _G.__probe_open_count(),
      string.format("all virtual documents must be closed after cleanup (didOpen=%d didClose=%d)", _G.__probe_didopen, _G.__probe_didclose)
    )
  end)
end)
