local vim = vim
local api = vim.api
local util = require 'utility'
local source = require 'source'
local lsp = require 'source.lsp'
local M = {}

------------------------------------------------------------------------
--                           local function                           --
------------------------------------------------------------------------

-- Manager variable to keep all state accross completion
local manager = {
  insertChar = false,
  insertLeave = false,
  textHover = false,
  selected = -1,
  changedTick = 0,
  changeSource = false
}

local autoCompletion = function(bufnr, line_to_cursor)
  -- Get the start position of the current keyword
  local textMatch = vim.fn.match(line_to_cursor, '\\k*$')
  local prefix = line_to_cursor:sub(textMatch+1)
  local length = api.nvim_get_var('completion_trigger_keyword_length')
  if (#prefix < length) then
    source.chain_complete_index = 1
  end
  if source.stop_complete == true then return end
  if (#prefix >= length or util.checkTriggerCharacter(line_to_cursor)) and api.nvim_call_function('pumvisible', {}) == 0 then
    source.triggerCurrentCompletion(manager, bufnr, prefix, textMatch)
  end
end


local autoOpenHoverInPopup = function(bufnr)
  if api.nvim_call_function('pumvisible', {}) == 1 then
    -- Auto open hover
    local item = api.nvim_call_function('complete_info', {{"eval", "selected", "items"}})
    if item['selected'] ~= manager.selected then
      manager.textHover = true
      if M.winnr ~= nil and api.nvim_win_is_valid(M.winnr) then
        api.nvim_win_close(M.winnr, true)
      end
      M.winner = nil
    end
    if manager.textHover == true and item['selected'] ~= -1 then
      if item['selected'] == -2 then
        item['selected'] = 0
      end
      if item['items'][item['selected']+1]['kind'] == 'UltiSnips' then
        -- TODO show Snippet information in floating window
      else
        local row, col = unpack(api.nvim_win_get_cursor(0))
        row = row - 1
        local line = api.nvim_buf_get_lines(0, row, row+1, true)[1]
        col = vim.str_utfindex(line, col)
        params = {
          textDocument = vim.lsp.util.make_text_document_params();
          position = { line = row; character = col-1; }
        }
        vim.lsp.buf_request(bufnr, 'textDocument/hover', params)
      end
      manager.textHover = false
    end
    manager.selected = item['selected']
  end
end

local autoOpenSignatureHelp = function(bufnr, line_to_cursor)
  local params = vim.lsp.util.make_position_params()
  if string.sub(line_to_cursor, #line_to_cursor, #line_to_cursor) == '(' then
    vim.lsp.buf_request(bufnr, 'textDocument/signatureHelp', params, function(_, method, result)
      if not (result and result.signatures and result.signatures[1]) then
        return
      else
        vim.lsp.util.focusable_preview(method, function()
          local lines = util.signature_help_to_preview_contents(result)
          lines = vim.lsp.util.trim_empty_lines(lines)
          if vim.tbl_isempty(lines) then
            return { 'No signature available' }
          end
          return lines, vim.lsp.util.try_trim_markdown_code_blocks(lines)
        end)
      end
    end)
  end
end

local completionManager = function()
  local bufnr = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  if api.nvim_get_var('completion_enable_auto_popup') == 1 then
    local status = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.synID(pos[1], pos[2]-1, 1)), "name")
    if status ~= 'Comment' or api.nvim_get_var('completion_enable_in_comment') == 1 then
      autoCompletion(bufnr, line_to_cursor)
    end
  end
  if api.nvim_get_var('completion_enable_auto_hover') == 1 then
    autoOpenHoverInPopup(bufnr)
  end
  if api.nvim_get_var('completion_enable_auto_signature') == 1 then
    autoOpenSignatureHelp(bufnr, line_to_cursor)
  end
end


------------------------------------------------------------------------
--                          member function                           --
------------------------------------------------------------------------

function M.confirmCompletion()
  api.nvim_call_function('completion#completion_confirm', {})
  local complete_item = api.nvim_get_vvar('completed_item')
  if complete_item.kind == 'UltiSnips' then
    api.nvim_call_function('UltiSnips#ExpandSnippet', {})
  elseif complete_item.kind == 'Neosnippet' then
    api.nvim_input("<c-r>".."=neosnippet#expand('"..complete_item.word.."')".."<CR>")
  end
  if M.winnr ~= nil and api.nvim_win_is_valid(M.winnr) then
    api.nvim_win_close(M.winnr, true)
  end
end


M.triggerCompletion = function(force)
  local bufnr = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  local textMatch = vim.fn.match(line_to_cursor, '\\k*$')
  local prefix = line_to_cursor:sub(textMatch+1)
  manager.insertChar = true
  -- force is used when manually trigger, so it doesn't repect the trigger word length
  local length = api.nvim_get_var('completion_trigger_keyword_length')
  if force == true or (#prefix >= length or util.checkTriggerCharacter(line_to_cursor)) then
    source.triggerCurrentCompletion(manager, bufnr, prefix, textMatch)
  end
end

function M.on_InsertCharPre()
  manager.insertChar = true
  manager.textHover = true
  manager.selected = -1
end

function M.on_InsertLeave()
  manager.insertLeave = true
end

function M.on_InsertEnter()
  local timer = vim.loop.new_timer()
  -- setup variable
  manager.changedTick = api.nvim_buf_get_changedtick(0)
  manager.insertLeave = false
  manager.insertChar = false
  manager.changeSource = false
  
  -- reset source
  source.chain_complete_index = 1
  source.stop_complete = false
  local l_complete_index = source.chain_complete_index

  timer:start(100, 50, vim.schedule_wrap(function()
    local l_changedTick = api.nvim_buf_get_changedtick(0)
    -- complete if changes are made
    if l_changedTick ~= manager.changedTick then
      manager.changedTick = l_changedTick
      completionManager()
    end
    -- change source if no item is available
    if manager.changeSource == true and api.nvim_get_var('completion_auto_change_source') == 1 then
      source.nextCompletion()
      manager.changeSource = false
    end
    -- force trigger completion if changing completion source
    if l_complete_index ~= source.chain_complete_index then
      M.triggerCompletion(false)
      l_complete_index = source.chain_complete_index
    end
    -- closing timer if leaving insert mode
    if manager.insertLeave == true and timer:is_closing() == false then
      timer:stop()
      timer:close()
    end
  end))
end

M.on_attach = function()
  require 'hover'.modifyCallback()
  api.nvim_command [[augroup CompletionCommand]]
    api.nvim_command("autocmd!")
    api.nvim_command("autocmd InsertEnter * lua require'completion'.on_InsertEnter()")
    api.nvim_command("autocmd InsertEnter * lua require'source'.on_InsertEnter()")
    api.nvim_command("autocmd InsertLeave * lua require'completion'.on_InsertLeave()")
    api.nvim_command("autocmd InsertCharPre * lua require'completion'.on_InsertCharPre()")
  api.nvim_command [[augroup end]]
  api.nvim_buf_set_keymap(0, 'i', api.nvim_get_var('completion_confirm_key'), '<cmd>call completion#wrap_completion()<CR>', {silent=true, noremap=true})
end

return M


