@echo on
REM -----------------------------------------------------------
REM  Refresh ReaPack index WITHOUT touching Git history
REM -----------------------------------------------------------
cd /d G:\Audio\Reaper\Scripts\Repo

REM ▸ Scan the working directory (including un-committed files)
REM   and update index.xml in place.
reapack-index -s . --amend --V
if errorlevel 1 (
    echo ** reapack-index reported an error – see above **
) else (
    echo.
    echo  index.xml updated – review & commit in SourceTree when ready.
)
pause
