vim9script noclear

if exists('loaded') | finish | endif
var loaded = true

# Documentation {{{1
#
# Basic usage is as follows:
#
#     sil! call repeat#set("\<plug>(my_map)", 3)
#
# The first  argument is the mapping  that will be  invoked when the `.`  key is
# pressed.
#
# The second  argument is the  default count.  This is  the number that  will be
# prefixed to the mapping if no  explicit numeric argument was given.  The value
# of the `v:count` variable  is usually correct and it will be  used if the second
# parameter is omitted.
#
# Make sure to call `repeat#set()` *after* making changes to the file.
#
# For  mappings  that  use  a  register  and want  the  same  register  used  on
# repetition, write:
#
#     " before any other command (they could reset `v:register`)
#     let regname = v:register
#     ...
#     " after all your other commands
#     sil! call repeat#setreg("\<plug>(my_map)", regname)

# FAQ {{{1
# `.` does not repeat my last *custom* command! {{{2
#
# It probably means that `repeat.tick` has not been properly updated.
# It can happen if some command is executed without triggering any event:
#
#      v-v
#     :noa update
#     " or
#     :au CursorHold * update
#
# Make sure they do trigger events:
#
#     :update
#     " or
#     :au CursorHold * ++nested update
#                      ^------^
#
# See `vim-save` for a real example where we found this pitfall.

# `.` does not repeat my mapping with the last count I used!{{{2
#
# At the start of your function, save the original count:
#
#     let cnt = v:count
#
# At the end of your function, pass it as a second argument to `#set()`.
#
#     sil! call repeat#set("\<plug>(MyMap)", cnt)
#                                            ^-^
#
# Explanation: If you don't pass a count to `#set()`, it will use `v:count`.
# But if your function executes a `:norm` command, `v:count` is reset.
# You don't want `#set()` to save this modified `v:count`; you want the original one.
#
#     ✘
#     $ vim -Nu NONE -S <(cat <<'EOF'
#         set rtp^=~/.vim/plugged/vim-repeat
#         au CursorMoved,TextChanged * "
#         nno <c-b> <cmd>call Func()<cr>
#         fu Func() abort
#             for i in range(v:count1)
#                 norm! 2dl
#             endfor
#             call repeat#set("\<c-b>")
#         endfu
#         sil pu!='aabbccdd'
#     EOF
#     )
#     " press:  C-b
#     "         .
#     " result:    dot deletes 4 characters
#     " expected:  dot deletes 2 characters
#
#     ✔
#     $ vim -Nu NONE -S <(cat <<'EOF'
#         set rtp^=~/.vim/plugged/vim-repeat
#         au CursorMoved,TextChanged * "
#         nno <c-b> <cmd>call Func()<cr>
#         fu Func() abort
#             let cnt = v:count
#         "   ^---------------^
#             for i in range(v:count1)
#                 norm! 2dl
#             endfor
#             call repeat#set("\<c-b>", cnt)
#         "                             ^-^
#         endfu
#         sil pu!='aabbccdd'
#     EOF
#     )
#     " press:  C-b
#     "         .
#     " result:    dot deletes 2 characters
#     " expected:  dot deletes 2 characters

# I have `set cpo+=y`, and my last command is `yy`.  `.` does not repeat it!  Instead, it repeats an older command! {{{2
#
#     $ vim -Nu NONE -S <(cat <<'EOF'
#         set rtp^=~/.vim/plugged/vim-repeat
#         au CursorMoved,TextChanged * "
#         nno <c-b> xp<cmd>call repeat#set('<c-b>')<cr>
#         %d
#         pu!='abc'
#         set cpo+=y
#     EOF
#     )
#     " press:  C-b
#               yy
#               .
#     " result:   dot repeats 'C-b'
#     " expected: dot repeats 'yy'
#
# The issue is due to the fact that a yanking does not increase `b:changedtick`.
#
# One solution would be to invoke `#invalidate()` when yanking some text, but it
# must be done only for an operation which is naturally repeatable.
# If you use a  custom command which yanks some text and  invokes `#set()` to be
# repeatable,  it should  not  invoke `#invalidate()`.   Making the  distinction
# between the  two is hard  (impossible?), so you  would need to  create wrapper
# mappings around all  possible yanking commands which  are naturally repeatable
# (e.g. `yiw`,  `yy`, ...),  and make them  invoke `#invalidate()`.   That's not
# manageable...
#
# For the  moment, the only solution  I can see is  to edit the buffer  to cause
# `b:changedtick` to increase.  For example, press `ddu` to delete a line and undo.

#}}}1

# Init {{{1

var repeat: dict<any> = {tick: -1, setreg: {seq: '', name: ''}}

const DEBUG: bool = false
if DEBUG
    g:repeat = repeat
endif

# Autocmd {{{1

augroup RepeatPlugin | au!
    # Purpose: Make sure the ticks are still synchronized whenever we read/write/reload a buffer,{{{
    # or when we focus a different buffer.
    #
    # Otherwise, right after any of these events occurs, `.` fails to repeat the
    # last custom command which has invoked `#set()`.
    #}}}

    # Wait.  `repeat.tick` is supposed to save `b:changedtick`.  Why do you reset it to 0 or -1?{{{
    #
    # Between a  `BufLeave`, `BufWritePre`,  `BufUnReadPre` event, and  the next
    # `BufEnter`,  `BufWritePost` event,  we  use `repeat.tick`  as a  temporary
    # boolean flag:
    #
    #      value | meaning
    #      ---------------
    #          0 | v:true
    #         -1 | v:false
    #}}}
    #   How can you do that?  Doesn't that make you lose the original value saved in `repeat.tick`?{{{
    #
    # Yes, but it doesn't matter; you don't need to remember it.
    #
    # If the ticks were synchronized, then `repeat.tick` is temporarily reset to
    # 0, and the ticks will be re-synchronized on `BufEnter` or `BufWritePost`.
    #
    # If the  ticks were *not*  synchronized, then `repeat.tick`  is temporarily
    # reset to -1, and nothing will happen on `BufEnter` or `BufWritePost`.
    # In  the  end, `repeat.tick`  will  have  been  definitively reset  to  -1,
    # which  is  a  good value,  because  no  matter  what's  the new  value  of
    # `b:changedtick`, it  can't be -1, so  the state of the  synchronization is
    # preserved (i.e. the ticks are still *un*equal).
    # In contrast, if  `repeat.tick` was not reset to -1,  and kept its original
    # value (e.g. 123),  there would be a  risk that it's accidentally  equal to
    # the  new `b:changedtick`,  which  would cause  `Dot()`  to wrongly  repeat
    # `repeat.set.seq`.
    #}}}
    #   Why 0 and -1?  Why not 0 and 1?{{{
    #
    # 1 is a valid value for `b:changedtick`.
    # To avoid any confusion, we want *invalid* values.
    #}}}

    # Why `BufReadPre`?{{{
    #
    # Tpope listens to it.  I have no idea why though.
    #}}}
    # Why `BufUnload`?{{{
    #
    # When you reload a buffer, `BufEnter` is fired but not `BufLeave`.
    # You need an event to hook into  and save the state of the synchronization,
    # so that you can restore it if necessary on `BufEnter`.
    # IOW,  you need  a  replacement  for `BufLeave`;  `BufUnload`  is the  only
    # possible event which can play this role.
    #
    # MWE:
    #
    #     # remove `BufUnload`
    #     $ vim -Nu NONE -S <(cat <<'EOF'
    #         set rtp^=~/.vim/plugged/vim-repeat
    #         au CursorMoved,TextChanged * "
    #         nno <c-b> xp<cmd>call repeat#set('<c-b>')<cr>
    #         %d
    #         pu!='abc'
    #     EOF
    #     ) /tmp/file
    #     " press:  C-b
    #               :w
    #               h (necessary to prevent the `CursorMoved` autocmd from fixing the bug by accident)
    #               :e
    #               .
    #     " result:   baac
    #     " expected: abc
    #
    # ---
    #
    # Note  that  `b:changedtick`  is  incremented by  1  on  `BufReadPre`  when
    # reloading a buffer, which is why the latter event is can't help here.
    #}}}
    # Why `|| repeat.tick == 0`?{{{
    #
    # To handle  the case  where the  first autocmd  is triggered  several times
    # consecutively, without the second one being triggered in between.
    # For example, suppose you do sth which triggers these events:
    #
    #    - `BufLeave`
    #    - `BufReadPre`
    #    - `BufEnter`
    #
    # After  `BufLeave`  has  been  fired,   the  meaning  of  `repeat.tick`  is
    # different;  it's no  longer a  saved `b:changedtick`,  but a  boolean flag
    # which stands for the state of the synchronization:
    #
    #      0 = ticks synchronized
    #     -1 = ticks *not* synchronized
    #
    # As a  result, when `BufReadPre`  is fired, `repeat.tick  == b:changedtick`
    # will *always* be false.  Obviously, this is wrong; it should be false only
    # if the ticks were not synchronized on `BufLeave`.
    # `||  repeat.tick ==  0`  makes sure  that  if the  boolean  flag was  true
    # (i.e. 0) on `BufLeave`, it is still true on `BufReadPre`.
    #
    # ---
    #
    # Here is an example illustrating the issue:
    #
    #     # remove `|| repeat.tick == 0`
    #     $ vim -Nu NONE -S <(cat <<'EOF'
    #         set rtp^=~/.vim/plugged/vim-repeat
    #         au CursorMoved,TextChanged * "
    #         nno <c-b> xp<cmd>call repeat#set('<c-b>')<cr>
    #         call writefile(['abc'], '/tmp/file1')
    #         call writefile(['abc'], '/tmp/file2')
    #         e /tmp/file1
    #     EOF
    #     )
    #     " press:  C-b u
    #     :e /tmp/file2
    #     " press:  .
    #     " result:  aabc
    #     " expected:  bac
    #
    # When `:e /tmp/file2` is run, these events are fired:
    #
    #    - `BufLeave`
    #    - `BufUnload`
    #    - `BufEnter`
    #}}}

    # Which alternative could I use to avoid `repeat.tick` from having a temporary different meaning?{{{
    #
    # I guess you could use an extra variable (e.g. `repeat.synced`):
    #
    #     au BufLeave,BufWritePre,BufReadPre,BufUnload *
    #        \ repeat.synced = repeat.tick == b:changedtick || repeat.synced
    #
    #     au BufEnter,BufWritePost *
    #          if repeat.synced
    #        |     repeat.tick = b:changedtick
    #        | else
    #        |     repeat.tick = 0
    #        | endif
    #        | repeat.synced = false
    #
    # This would require a few other changes:
    #
    #     repeat: dict<any> = {tick: -1, setreg: {seq: '', name: ''}}
    #     →
    #     repeat: dict<any>= {tick: 0, setreg: {seq: '', name: ''}, synced: false}
    #                               ^                               ^-----------^
    #
    #     def repeat#invalidate()
    #         repeat.tick = -1
    #     →
    #     def repeat#invalidate()
    #         repeat.tick = 0
    #}}}
    #   Why don't you use it?{{{
    #
    # It  makes the  code a  little more  verbose, and  I'm not  100% sure  it's
    # equivalent to tpope's code.
    #}}}
    au BufLeave,BufWritePre,BufReadPre,BufUnload *
        \ repeat.tick = (repeat.tick == b:changedtick || repeat.tick == 0) ? 0 : -1
    au BufEnter,BufWritePost *
        \ if repeat.tick == 0 | repeat.tick = b:changedtick | endif
augroup END

# Mappings {{{1

# Don't use `v:count1`.{{{
#
# We want to be able to use the variable in a simple true/false test.
# `v:count` can be used for that:
#
#     if v:count
#         " some count was used
#     else
#         " no count was used
#     endif
#
# It works because `v:count` is 0 when no explicit count was pressed.
#}}}
nno <unique> . <cmd>call <sid>Dot(v:count)<cr>

# Why remapping `u`, `U` and `C-r`?{{{
#
# It's the only commands which can increase `b:changedtick` without altering the
# behavior of the dot command.  IOW, when  you use them, Vim's `.` still repeats
# the same  command; for  vim-repeat's `.`  to behave just  like Vim's  `.`, the
# ticks synchronization need to be preserved whenever `u` or `C-r` is executed.
#}}}
nno <unique> u <cmd>call <sid>Wrap('u', v:count)<cr>
nno <unique> <c-r> <cmd>call <sid>Wrap('<c-r>', v:count)<cr>
if maparg('U') == ''
    nno <unique> U <cmd>call <sid>Wrap('U', v:count)<cr>
endif

# Functions {{{1
# Interface {{{2
def repeat#set(sequence: string, count = 0) #{{{3
    repeat.set = {seq: sequence, count: count != 0 ? count : v:count}
    repeat.tick = b:changedtick
    # Some plugin may inspect `g:repeat_sequence`.{{{
    #
    # That's the case – for example – of `vim-matchup`:
    #
    #     ~/.vim/plugged/vim-matchup/autoload/matchup/surround.vim:69
    #}}}
    g:repeat_sequence = sequence
    augroup RepeatCustomMotion | au!
        # Should it be `au! * <buffer>`?{{{
        #
        # In theory yes, but I don't think  it matters here; I don't see how the
        # autocmd could ever be installed in several buffers at the same time.
        # And if somehow that happens, I  prefer to clear too many autocmds than
        # too few.  Too  many implies that `.` fails to  repeat a custom command
        # relying on `#set()`.  Too few implies  that `.` could fail to repeat a
        # naturally  repeatable command  (e.g. `g@`).   The latter  commands are
        # much more numerous, so their reliability is more important.
        #
        # In  any case,  if you  write `au!  * <buffer>`  here, do  the same  in
        # `#invalidate()`.
        #}}}
        # Support invocation from operator-pending mode.{{{
        #
        # If   `#set()`   is   invoked    from   operator-pending   mode,   then
        # `b:changedtick` is not incremented until the operator command has been
        # fully executed:
        #
        #     $ vim -Nu NONE -S <(cat <<'EOF'
        #         omap <c-b> <cmd>call Func()<cr>
        #         fu Func()
        #             norm! l
        #             echom b:changedtick
        #         endfu
        #         pu!='abcd'
        #     EOF
        #     )
        #     " press: d C-b
        #     :echom b:changedtick
        #     :mess
        #     3~
        #     4~
        #
        # Because  of this,  synchronizing the  ticks right  now is  useless; it
        # needs to be done later, e.g. on `CursorMoved`.
        # It works because the latter is not fired in operator-pending mode.
        # From `:h CursorMoved`:
        #
        #    > Not triggered when there is typeahead or when
        #    > an operator is pending.
        #
        # See: https://github.com/tpope/vim-repeat/issues/8#issuecomment-13951082
        #}}}
        #   Is this really needed?{{{
        #
        # Usually, I don't think so.
        # Even if the  ticks are desynchronized, the native `.`  command will be
        # executed, and will correctly repeat the last operator + text-object.
        #
        # But it may have been useful for some omaps before 7.3.918.
        # However, it *is* needed for `vim-sneak` (to repeat sth like `dfx`):
        #
        #     $ vim -Nu NONE -S <(cat <<'EOF'
        #         set rtp^=~/.vim/plugged/vim-repeat
        #         au CursorMoved,TextChanged * "
        #         ono <c-b> <cmd>call Textobj()<cr>
        #         fu Textobj() abort
        #             let input = getchar()->nr2char()
        #             call search(input)
        #             call repeat#set(v:operator .. "\<c-b>" .. input)
        #         endfu
        #     EOF
        #     ) +"pu!=['abxy', 'abxy']" +1
        #     " press: d C-b x
        #              j .
        #
        # If you  want the last dot  command to repeat  `d C-b x`, you  need the
        # next autocmd, so  that the ticks are synchronized and  the sequence is
        # manually fed when you press `.`.
        # Without the autocmd, the ticks  won't be synchronized, and the wrapper
        # around `.` will execute the native `.` which will simply repeat `d C-b`.
        # From Vim's point  of view, `x` is not an  operator, nor a text-object;
        # you'll need to re-input `x`.
        #}}}
        au CursorMoved <buffer> ++once repeat.tick = b:changedtick
    augroup END
enddef

def repeat#setreg(seq: string, name: string) #{{{3
    repeat.setreg = {seq: seq, name: name}
enddef

def repeat#invalidate(): string #{{{3
    # Why resetting the tick?{{{
    #
    # Suppose you use a custom command which invokes `repeat#set()` to be repeatable
    # (e.g. `dfx`, `f` being mapped by `vim-sneak` in operator-pending mode).
    #
    # Then, you  press `cxx`  to exchange  the current  line with  another line.
    # Finally, you move to another line and press `.` to exchange that line with
    # the previous one.  It won't work.  Indeed, when you press `cxx`:
    #
    #    1. the buffer is not modified by the command
    #    2. `b:changedtick` is not increased
    #    3. `b:changedtick` and `repeat.tick` are still synchronized, and so
    #       `Dot()` will repeat the last sequence which was saved the last time
    #       `repeat#set()` was invoked (i.e. `dfx`)
    #
    # To  fix  this,  the  function  implementing `cxx`  needs  to  be  able  to
    # invalidate  the  cache  of  vim-repeat.    That's  the  whole  purpose  of
    # `#invalidate()`.
    #
    # See:
    # https://github.com/tommcdo/vim-exchange/pull/32#issuecomment-69506716
    # https://github.com/tommcdo/vim-exchange/pull/32#issuecomment-69509516
    # https://github.com/tpope/vim-repeat/commit/476c28084e210dd4a9943d3e9235ed588f2b9d28
    #}}}
    repeat.tick = -1
    # Why clearing this autocmd?{{{
    #
    # Theory: Suppose you use a custom command invoking `#set()`.
    # Then, without making the cursor move, you use another custom command which
    # invokes  `#invalidate()`.  When  the  cursor will  be  finally moved,  the
    # autocmd will wrongly re-synchronize the  ticks.  Clearing it prevents such
    # a pitfall.
    #
    # See: https://github.com/tpope/vim-repeat/commit/80261bc53193c7e602373c6da78180aabbeb4b77
    #}}}
    if exists('#RepeatCustomMotion')
        au! RepeatCustomMotion
    endif
    return ''
enddef
#}}}2
# Core {{{2
def Dot(count: number) #{{{3
    # If the ticks are different, it means the last command did not invoke `#set()`.{{{
    #
    # We can't repeat it, because we don't know what it is.
    # It's probably a naturally repeatable command (e.g. `dd`).
    # In any case, we let the native dot command repeat it.
    #}}}
    var cnt: string
    if repeat.tick != b:changedtick
        # if we've pressed `3.`, we want the wrapper to run `3.`
        cnt = count != 0 ? count->string() : ''
        return feedkeys(cnt .. '.', 'in')
    endif

    var seq: string = repeat.set.seq
    var reg: string = Getreg()
    cnt = Getcnt(count)
    # the last command did invoke `#set()`; let's repeat it
    # Wait.  Isn't the order of the keys wrong?{{{
    #
    # No.  Notice how all the keys are *inserted* and not appended.
    #
    #     typeahead
    #     ^-------^
    #     whatever is currently written in the typehead
    #
    #     feedkeys(repeat.set.seq, 'i')
    #     →
    #     seq typehead
    #     ^^^
    #
    #     feedkeys(Getreg() .. Getcnt(count), 'in')
    #     →
    #     reg cnt seq typehead
    #     ^---------^
    #     the order is correct (e.g. "a3dd)
    #}}}
    feedkeys(seq, 'i')
    feedkeys(reg .. cnt, 'in')
enddef

def Wrap(command: string, count: number) #{{{3
    # return feedkeys('u', 'in')
    var ticks_synchronized: bool = repeat.tick == b:changedtick
    # Don't use the `t` flag to make Vim automatically open a possible fold.
    # During a recording, it would cause the undo/redo command to be recorded twice.
    var seq: string = (count ? count : '') .. command
    feedkeys(seq, 'in')
    # Delay the synchronization until the undo/redo command has been executed.
    # Is there an alternative?{{{
    #
    # You could also listen to `SafeState`, or maybe `CursorMoved`.
    #
    # ---
    #
    # You could try to tweak the  flags passed to the previous `feedkeys()`, but
    # it's tricky.
    #
    # First, you'll have to use the `x` flag.
    # The undo  command needs to be  run *now*, so  that we can inspect  the new
    # `b:changedtick` and correctly synchronize it with `repeat.tick`.
    #
    # Otherwise,  the   undo  will  be  run   later,  and  the  ticks   will  be
    # desynchronized which will cause the next redo to fail.
    #
    # https://github.com/tpope/vim-repeat/issues/63#issue-323810749
    #
    # But I'm  concerned by unexpected  side-effects due to executing  *all* the
    # typeahead.   Remember that  `:norm` *inserts*  keys, so  it can  limit the
    # execution to only the keys it presses.
    #
    # ---
    #
    # You could also try to use `:norm`:
    #
    #     feedkeys((count ? count : '') .. command, 'in')
    #     →
    #     exe 'norm! ' .. (count ? count : '') .. command
    #
    # But it would prevent `u`, `U`, and `C-r` from printing some info about the undo state:
    # https://github.com/tpope/vim-repeat/issues/27
    #}}}
    # Why the `foldclosed()` guard?{{{
    #
    # First, `zv` prevents `u`, `U`, and `C-r` from printing some info about the
    # undo state: https://github.com/tpope/vim-repeat/issues/27
    #
    # Second,  if the  cursor is  not in  a closed  fold, there's  no reason  to
    # execute `zv`.  The latter may  have other subtle undesirable side-effects;
    # the less often we execute it, the better.
    #}}}
    if ticks_synchronized
        au TextChanged <buffer> ++once repeat.tick = b:changedtick
            | if &foldopen =~ 'undo\|all' && foldclosed('.') >= 0
            |     feedkeys('zv', 'in')
            | endif
    endif
enddef

def Getcnt(dotcount: number): string #{{{3
    var setcount: number = repeat.set.count
    # If `.` was prefixed by a count, use it.{{{
    #
    # We want it to  have priority over whatever count was  saved by `#set()` so
    # that our wrapper around `.` emulates the behavior of the native `.`:
    #
    #     $ vim -Nu NONE +"sil pu!=range(1, 10)|1"
    #     " press:  2dd
    #               3.
    #
    # `3.` deletes 3 lines.
    # The counts are not combined (multiplied);  the count in front of `.` (here
    # `3`) simply has priority over the original count (here `2`).
    #}}}
    if dotcount != 0
        return dotcount->string()
    # If the last command was prefixed by a count, use it again.{{{
    #
    # So that our wrapper around `.` emulates the native `.`:
    #
    #     $ vim -Nu NONE +"sil pu!=range(1, 10)|1"
    #     " press:  2dd
    #               .
    #
    # `.` deletes 2 lines; it repeats the last command *and* the last count.
    #}}}
    elseif setcount != 0
        return setcount->string()
    else
        return ''
    endif
enddef

def Getreg(): string #{{{3
    var reg: string = ''

    # `.` was not prefixed by a register
    if v:register == '"'
        # try to use the register set by `#setreg()`
        # Sanity checks.{{{
        #
        # Check that the sequences we've passed to `#set()` and `#setreg()` are identical.
        # And check that we have passed a non-empty register name to `#setreg()`.
        #}}}
        if repeat.setreg.seq == repeat.set.seq && repeat.setreg.name == ''
            reg = '"' .. repeat.setreg.name
        endif
    # `.` *was* prefixed by a register; use it
    # See: https://github.com/tpope/vim-repeat/commit/0b9b5e742f67bc81ae4a1f79318549d3afc90b13
    else
        reg = '"' .. v:register
    endif

    if reg == '"='
        # Why the 1 argument?{{{
        #
        # We don't want to re-use the  last evaluation; we want to *re*-evaluate
        # the expression itself.
        #}}}
        reg = '"=' .. getreg('=', true) .. "\r"
    endif

    return reg
enddef

