" A simple wiki plugin for Vim
"
" Maintainer: Karl Yngve Lervåg
" Email:      karl.yngve@gmail.com
"

function! wiki#page#open(...) abort "{{{1
  let l:page = a:0 > 0 ?
        \ a:1
        \ : wiki#ui#input(#{info: 'Open page (or create new): '})
  if empty(l:page) | return | endif

  if !empty(g:wiki_map_create_page)
        \ && (type(g:wiki_map_create_page) == v:t_func
        \     || exists('*' . g:wiki_map_create_page))
    let l:page = call(g:wiki_map_create_page, [l:page])
  endif

  call wiki#url#parse('wiki:/' . l:page).follow()
endfunction

"}}}1
function! wiki#page#delete() abort "{{{1
  if !wiki#ui#confirm(printf('Delete "%s"?', expand('%')))
    return
  endif

  let l:filename = expand('%:p')
  try
    call delete(l:filename)
  catch
    return wiki#log#error('Cannot delete "%s"!', expand('%:t:r'))
  endtry

  call wiki#nav#return()
  execute 'bdelete!' fnameescape(l:filename)
endfunction

"}}}1
function! wiki#page#rename(...) abort "{{{1
  " This function renames a wiki page to a new name. The names used here are
  " filenames without the extension. The outer function parses the options and
  " validates the parameters before passing them to dedicated private
  " functions.
  "
  " Input: An optional dictionary with the following keys:
  "   dir_mode: "ask" (default), "abort" or "create"
  "   new_name: The new page name

  " Does not support renaming files inside journal
  if b:wiki.in_journal
    return wiki#log#error('Not supported yet.')
  endif

  let l:opts = extend(#{
        \ dir_mode: 'ask'
        \}, a:0 > 0 ? a:1 : {})

  if index(['abort', 'ask', 'create'], l:opts.dir_mode) < 0
    return wiki#log#error(
          \ 'The dir_mode option for wiki#page#rename must be one of',
          \ '"abort", "ask", or "create"!',
          \ 'Recieved: ' . l:opts.dir_mode,
          \)
  end

  " Check if current file exists
  let l:path_old = expand('%:p')
  if !filereadable(l:path_old)
    return wiki#log#error(
          \ 'Cannot rename "' . l:path_old . '".',
          \ 'It does not exist! (New file? Save it before renaming.)'
          \)
  endif

  if !has_key(l:opts, 'new_name')
    let l:opts.new_name = wiki#ui#input(
          \ #{info: 'Enter new name (without extension) [empty cancels]:'})
  endif
  if empty(l:opts.new_name) | return | endif

  " The new name must be nontrivial
  if empty(substitute(l:opts.new_name, '\s*', '', ''))
    return wiki#log#error('Cannot rename to a whitespace filename!')
  endif

  " The target path must not exist
  let l:path_new = wiki#paths#s(printf('%s/%s.%s',
        \ expand('%:p:h'), l:opts.new_name, b:wiki.extension))
  if filereadable(l:path_new)
    return wiki#log#error(
          \ 'Cannot rename to "' . l:path_new . '".',
          \ 'File with that name exist!'
          \)
  endif

  " Check if target directory exists
  let l:target_dir = fnamemodify(l:path_new, ':p:h')
  if !isdirectory(l:target_dir)
    if l:opts.dir_mode ==# 'abort'
      call wiki#log#warn(
            \ 'Directory "' . l:target_dir . '" does not exist. Aborting.')
      return
    elseif l:opts.dir_mode ==# 'ask'
      if !wiki#ui#confirm([
            \ prinft('Directory "%s" does not exist.', l:target_dir),
            \ 'Create it?'
            \])
        return
      endif
    end

    call wiki#log#info('Creating directory "' . l:target_dir . '".')
    call mkdir(l:target_dir, 'p')
  endif

  try
    call s:rename_files(l:path_old, l:path_new)
  catch
    return wiki#log#error(
          \ printf('Cannot rename "%s" to "%s" ...',
          \   fnamemodify(l:path_old, ':t'),
          \   fnamemodify(l:path_new, ':t')))
  endtry

  call s:update_links(l:path_old, l:path_new)

  " Tag data may be changed as a result of the renaming
  silent call wiki#tags#reload()
endfunction

" }}}1

function! wiki#page#rename_section() abort "{{{1
  call wiki#page#rename_section_to(
        \ wiki#ui#input(#{info: 'Enter new section name:'}))
endfunction

" }}}1
function! wiki#page#rename_section_to(newname) abort "{{{1
  let l:section = wiki#toc#get_section_at(line('.'))
  if empty(l:section)
    return wiki#log#error('No current section recognized!')
  endif

  call wiki#log#info(printf('Renaming section from "%s" to "%s"',
        \ l:section.header, a:newname))

  " Update header
  call setline(l:section.lnum,
        \ printf('%s %s',
        \   repeat('#', l:section.level),
        \   a:newname))

  " Update local anchors
  let l:pos = getcurpos()
  let l:new_anchor = join([''] + l:section.anchors[:-2] + [a:newname], '#')
  keepjumps execute '%s/\V' . l:section.anchor
        \ . '/' . l:new_anchor
        \ . '/e' . (&gdefault ? '' : 'g')
  call cursor(l:pos[1:])
  silent update

  " Update remote anchors
  let l:graph = wiki#graph#builder#get()
  let l:links = l:graph.get_links_to(expand('%:p'))
  call filter(l:links, { _, x -> x.filename_from !=# x.filename_to })
  call filter(l:links, { _, x -> '#' . x.anchor =~# l:section.anchor })

  let l:grouped_links = wiki#u#group_by(l:links, 'filename_from')

  let l:n_files = 0
  let l:n_links = 0
  for [l:file, l:links] in items(l:grouped_links)
    let l:n_files += 1
    call wiki#log#info('Updating links in: ' . fnamemodify(l:file, ':t'))
    let l:lines = readfile(l:file)
    for l:link in l:links
      let l:n_links += 1
      let l:line = l:lines[l:link.lnum - 1]
      let l:lines[l:link.lnum - 1] = substitute(
            \ l:lines[l:link.lnum - 1],
            \ '\V' . l:section.anchor,
            \ l:new_anchor,
            \ 'g')
    endfor
    call writefile(l:lines, l:file)
  endfor

  call wiki#log#info(
        \ printf('Updated %d links in %d files', l:n_links, l:n_files))
endfunction

" }}}1

function! wiki#page#export(line1, line2, ...) abort " {{{1
  let l:cfg = deepcopy(g:wiki_export)
  let l:cfg.fname = ''

  let l:args = copy(a:000)
  while !empty(l:args)
    let l:arg = remove(l:args, 0)
    if l:arg ==# '-args'
      let l:cfg.args = remove(l:args, 0)
    elseif l:arg =~# '\v^-f(rom_format)?$'
      let l:cfg.from_format = remove(l:args, 0)
    elseif l:arg ==# '-ext'
      let l:cfg.ext = remove(l:args, 0)
    elseif l:arg ==# '-output'
      let l:cfg.output = remove(l:args, 0)
    elseif l:arg ==# '-link-ext-replace'
      let l:cfg.link_ext_replace = v:true
    elseif l:arg ==# '-view'
      let l:cfg.view = v:true
    elseif l:arg ==# '-viewer'
      let l:cfg.view = v:true
      let l:cfg.viewer = remove(l:args, 0)
    elseif empty(l:cfg.fname)
      let l:cfg.fname = expand(simplify(l:arg))
    else
      return wiki#log#error(
            \ 'WikiExport argument "' . l:arg . '" not recognized',
            \ 'Please see :help WikiExport'
            \)
    endif
  endwhile

  " Ensure output directory is an absolute path
  if !wiki#paths#is_abs(l:cfg.output)
    let l:cfg.output = wiki#get_root() . '/' . l:cfg.output
  endif

  " Ensure output directory exists
  if !isdirectory(l:cfg.output)
    call mkdir(l:cfg.output, 'p')
  endif

  " Determine output filename and extension
  if empty(l:cfg.fname)
    let l:cfg.fname = wiki#paths#s(printf('%s/%s.%s',
          \ l:cfg.output, expand('%:t:r'), l:cfg.ext))
  else
    let l:cfg.ext = fnamemodify(l:cfg.fname, ':e')
  endif

  " Ensure '-link-ext-replace' is combined wiht '-ext html'
  if l:cfg.link_ext_replace && l:cfg.ext !=# 'html'
    return wiki#log#error(
          \ 'WikiExport option conflict!',
          \ 'Note: Option "-link-ext-replace" only works with "-ext html"',
          \)
  endif

  " Generate the output file
  call s:export(a:line1, a:line2, l:cfg)
  call wiki#log#info('Page was exported to ' . l:cfg.fname)

  if l:cfg.view
    call call(has('nvim') ? 'jobstart' : 'job_start',
          \ [[get(l:cfg, 'viewer', get(g:wiki_viewer,
          \     l:cfg.ext, g:wiki_viewer['_'])), l:cfg.fname]])
  endif
endfunction

" }}}1

function! s:rename_files(path_old, path_new) abort "{{{1
  let l:bufnr = bufnr('')
  call wiki#log#info(
        \ printf('Renaming "%s" to "%s" ...',
        \   fnamemodify(a:path_old, ':t'),
        \   fnamemodify(a:path_new, ':t')))
  if rename(a:path_old, a:path_new) != 0
    throw 'wiki.vim: Cannot rename file!'
  end

  " Open new file and remove old buffer
  execute 'silent edit' a:path_new
  execute 'silent bwipeout' l:bufnr
endfunction

" }}}1
function! s:update_links(path_old, path_new) abort "{{{1
  let l:current_bufnr = bufnr('')

  " Save all open wiki buffers (prepare for updating links)
  let l:wiki_bufnrs = filter(range(1, bufnr('$')),
        \ {_, x -> buflisted(x) && !empty(getbufvar(x, 'wiki'))})
  for l:bufnr in l:wiki_bufnrs
    execute 'buffer' l:bufnr
    update
  endfor

  " Update links
  let l:graph = wiki#graph#builder#get()
  let l:all_links = l:graph.get_links_to(a:path_old)
  let l:files_with_links = wiki#u#group_by(l:all_links, 'filename_from')
  let l:replacement_patterns
        \ = s:get_replacement_patterns(a:path_old, a:path_new)
  for [l:file, l:file_links] in items(l:files_with_links)
    let l:lines = readfile(l:file)

    for l:link in l:file_links
      for [l:pattern, l:replace] in l:replacement_patterns
        let l:lines[l:link.lnum - 1] = substitute(
              \ l:lines[l:link.lnum - 1],
              \ l:pattern,
              \ l:replace,
              \ 'g'
              \)
      endfor
    endfor

    call writefile(l:lines, l:file)
  endfor

  " Move graph nodes from old to new path
  let l:graph.map[a:path_new] = deepcopy(l:graph.map[a:path_old])
  unlet l:graph.map[a:path_old]

  call wiki#log#info(printf('Updated %d links in %d files',
        \ len(l:all_links), len(l:files_with_links)))

  " Refresh other wiki buffers
  for l:bufnr in l:wiki_bufnrs
    execute 'buffer' l:bufnr
    edit
  endfor

  " Restore the original buffer
  execute 'buffer' l:current_bufnr
endfunction

" }}}1
function! s:get_replacement_patterns(path_old, path_new) abort " {{{1
  let l:root = wiki#get_root()

  " Update "absolute" links (i.e. assume link is rooted)
  let l:url_old = s:path_to_url(l:root, a:path_old)
  let l:url_new = s:path_to_url(l:root, a:path_new)
  let l:url_pairs = [[l:url_old, l:url_new]]

  " Update "relative" links (look within the specific common subdir)
  let l:subdirs = []
  let l:old_subdirs = split(l:url_old, '\/')[:-2]
  let l:new_subdirs = split(l:url_new, '\/')[:-2]
  while !empty(l:old_subdirs)
        \ && !empty(l:new_subdirs)
        \ && l:old_subdirs[0] ==# l:new_subdirs[0]
    call add(l:subdirs, remove(l:old_subdirs, 0))
    call remove(l:new_subdirs, 0)
  endwhile
  if !empty(l:subdirs)
    let l:root .= '/' . join(l:subdirs, '/')
    let l:url_pairs += [[
          \ s:path_to_url(l:root, a:path_old),
          \ s:path_to_url(l:root, a:path_new)
          \]]
  endif

  " Create pattern to match relevant old link urls
  let l:replacement_patterns = []
  for [l:url_old, l:url_new] in l:url_pairs
    let l:re_url_old = '(\.\/|\/)?' . escape(l:url_old, '.')
    let l:pattern = '\v' . join([
          \ '\[\[\zs' . l:re_url_old . '\ze%(#.*)?%(\|.*)?\]\]',
          \ '\[.*\]\(\zs' . l:re_url_old . '\ze%(#.*)?\)',
          \ '\[.*\]\[\zs' . l:re_url_old . '\ze%(#.*)?\]',
          \ '\[\zs' . l:re_url_old . '\ze%(#.*)?\]\[\]',
          \ '\<\<\zs' . l:re_url_old . '\ze#,[^>]{-}\>\>',
          \], '|')
    let l:replacement_patterns += [[l:pattern, l:url_new]]
  endfor

  return l:replacement_patterns
endfunction

" }}}1
function! s:path_to_url(root, path) abort " {{{1
  let l:path = wiki#paths#relative(a:path, a:root)
  let l:ext = '.' . fnamemodify(l:path, ':e')

  return l:ext ==# g:wiki_link_extension
        \ ? l:path
        \ : fnamemodify(l:path, ':r')
endfunction

" }}}1

function! s:export(start, end, cfg) abort " {{{1
  let l:fwiki = expand('%:p') . '.tmp'

  " Parse wiki page content
  let l:lines = getline(a:start, a:end)
  if a:cfg.link_ext_replace
    call s:convert_links_to_html(l:lines)
  endif

  let l:wiki_link_rx = '\[\[#\?\([^\\|\]]\{-}\)\]\]'
  let l:wiki_link_text_rx = '\[\[[^\]]\{-}|\([^\]]\{-}\)\]\]'
  call map(l:lines, 'substitute(v:val, l:wiki_link_rx, ''\1'', ''g'')')
  call map(l:lines, 'substitute(v:val, l:wiki_link_text_rx, ''\1'', ''g'')')
  call writefile(l:lines, l:fwiki)

  " Construct pandoc command
  let l:cmd = printf('pandoc %s -f %s -o %s %s',
        \ a:cfg.args,
        \ a:cfg.from_format,
        \ shellescape(a:cfg.fname),
        \ shellescape(l:fwiki))

  " Execute pandoc command
  call wiki#paths#pushd(fnamemodify(l:fwiki, ':h'))
  let l:output = wiki#jobs#capture(l:cmd)
  call wiki#paths#popd()

  if v:shell_error == 127
    return wiki#log#error('Pandoc is required for this feature.')
  elseif v:shell_error > 0
    return wiki#log#error(
          \ 'Something went wrong when running cmd:',
          \ l:cmd,
          \ 'Shell output:',
          \ join(l:output, "\n"),
          \)
  endif

  call delete(l:fwiki)
endfunction

" }}}1
function! s:convert_links_to_html(lines) abort " {{{1
  if g:wiki_link_target_type ==# 'md'
    let l:rx = '\[\([^\\\[\]]\{-}\)\]'
          \ . '(\([^\(\)\\]\{-}\)' . g:wiki_link_extension
          \ . '\(#[^#\(\)\\]\{-}\)\{-})'
    let l:sub = '[\1](\2.html\3)'
  elseif g:wiki_link_target_type ==# 'wiki'
    let l:rx = '\[\[\([^\\\[\]]\{-}\)' . g:wiki_link_extension
          \ . '\(#[^#\\\[\]]\{-}\)'
          \ . '|\([^\[\]\\]\{-}\)\]\]'
    let l:sub = '\[\[\1.html\2|\3\]\]'
  else
    return wiki#log#error(
          \ 'g:wiki_link_target_type must be `md` or `wiki` to replace',
          \ 'link extensions on export.'
          \)
  endif

  call map(a:lines, 'substitute(v:val, l:rx, l:sub, ''g'')')
endfunction

" }}}1
