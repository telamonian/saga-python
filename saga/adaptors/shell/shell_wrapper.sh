#!/bin/sh

# be friendly to bash users (and yes, the leading space is on purpose)
HISTIGNORE='*'
export HISTIGNORE

# this script uses only POSIX shell functionality, and does not rely on bash or
# other shell extensions.  It expects /bin/sh to be a POSIX compliant shell
# thought.


# --------------------------------------------------------------------
# on argument quoting
#
#   method "a b c" 'd e' f g
#   method() {
#     echo $*     # 'a' 'b' 'c' 'd' 'e' 'f' 'g'
#     echo $@     # 'a' 'b' 'c' 'd' 'e' 'f' 'g'
#     echo "$*"   # 'a b c d e f g'
#     echo "$@"   # 'a b c' 'd e' 'f' 'g'
#   }
#
# on tracing:
# http://www.unix.com/shell-programming-and-scripting/165648-set-x-within-script-capture-file.html


# --------------------------------------------------------------------
#
# Fucking /bin/kill by Ubuntu sometimes understands --, sometimes does not :-P
# We need to check the version, and assume that prior to 3.3.0 it is not
# understood
KILL_DASHES="--"
KILL_VERSION=`/bin/kill --version 2>&1 | tr -d -c '[:digit:]'`
if test 330 -gt "$KILL_VERSION"
then
  KILL_DASHES=""
fi

# we always start in the user's home dir
\cd $HOME 2>&1 > /dev/null


# --------------------------------------------------------------------
#
# ERROR and RETVAL are used for return state from function calls
#
ERROR=""
RETVAL=""

# this is where this 'daemon' keeps state for all started jobs
BASE=$HOME/.saga/adaptors/shell_job/
NOTIFICATIONS="$BASE/notifications"

# this process will terminate when idle for longer than TIMEOUT seconds
TIMEOUT=30

# update timestamp function
TIMESTAMP=0

PURGE_ON_START="%(PURGE_ON_START)s"

# default exit value is 1, for error.  We need to set explicitly to 0 for
# non-error conditions.
EXIT_VAL=1

# --------------------------------------------------------------------
#
# idle_checker is running in the background, and will terminate the wrapper
# shell if it is idle for longer than TIMEOUT seconds
#
\trap cleanup_handler QUIT TERM EXIT
# trap idle_handler ALRM
\trap '' ALRM

cleanup_handler (){
  cmd_quit $IDLE
}

idle_handler (){
  cmd_quit TIMEOUT
}

idle_checker () {

  ppid=$1

  while true
  do
    \sleep $TIMEOUT

    if test -e "$BASE/quit.$ppid" 
    then
      \rm   -f  "$BASE/quit.$ppid" 
      EXIT_VAL=0
      exit 0
    fi

    if test -e "$BASE/idle.$ppid"
    then
      /bin/kill -s ALRM $ppid >/dev/null 2>&1
      \rm   -f  "$BASE/idle.$ppid" 
      exit 0
    fi

    \touch "$BASE/idle.$ppid"
  done
}


# --------------------------------------------------------------------
#
# When sending command stdout and stderr back, we encode into 
# hexadecimal via od, to keep the protocol simple.  This is done by 
# the 'encode' function which sets 'ENCODED' to the result of that 
# conversion for all given string parameters.  For completeness, we 
# also give the matching 'decode' function, although we don't use it
# in this shell wrapper script itself.  'decode' consumes the output 
# of 'encode' and stores the resulting string in 'DECODED'.  Any 
# elements for which decoding fails are complained about in 'RETVAL', 
# which remains otherwise empty on successful decoding.
#
encode () {
  ENCODED="`echo \"$*\" | od -t x1 -A n #| cut -c 2- | tr -d ' \n'`"
  echo $ENCODED
}

decode () {
  CODE=""
  SKIPPED=""
  RETVAL=""
  for word in $*; do
    case "$word" in 
      [0-9a-f][0-9a-f] )
        CODE="$CODE\x$word"
        ;;
      * )
        SKIPPED="$SKIPPED $word"
        ;;
    esac
  done
  DECODED=`/usr/bin/printf "$CODE"`
  if ! test -z "$SKIPPED"; then
    RETVAL="skip decoding of [$SKIPPED ]"
  fi
}



# --------------------------------------------------------------------
#
# it is suprisingly difficult to get seconds since epoch in POSIX -- 
# 'date +%%s' is a GNU extension...  Anyway, awk to the rescue! 
#
timestamp () {
  TIMESTAMP=`\awk 'BEGIN{srand(); print srand()}'`
}


# --------------------------------------------------------------------
# ensure that a given job id points to a viable working directory
verify_dir () {
  if test -z $1 ;            then ERROR="no pid given";        return 1; fi
  DIR="$BASE/$1"
  if ! test -d "$DIR";       then ERROR="pid $1 not known";    return 1; fi
}


# --------------------------------------------------------------------
# ensure that given job id has valid pid file
verify_pid () {
  verify_dir $1
  if ! test -r "$DIR/rpid";  then ERROR="pid $1 has no process id"; return 1; fi
}


# --------------------------------------------------------------------
# ensure that given job id has valid state file
verify_state () {
  verify_dir $1
  if ! test -r "$DIR/state"; then ERROR="pid $1 has no state"; return 1; fi
}


# --------------------------------------------------------------------
# ensure that given job id has valid stdin file
verify_in () {
  verify_dir $1
  if ! test -r "$DIR/in";    then ERROR="pid $1 has no stdin"; return 1; fi
}


# --------------------------------------------------------------------
# ensure that given job id has valid stdout file
verify_out () {
  verify_dir $1
  if ! test -r "$DIR/out";   then ERROR="pid $1 has no stdout"; return 1; fi
}


# --------------------------------------------------------------------
# ensure that given job id has valid stderr file
verify_err () {
  verify_dir $1
  if ! test -r "$DIR/err";   then ERROR="pid $1 has no stderr"; return 1; fi
}


# --------------------------------------------------------------------
#
# create the monitor script, used by the command running routines.
#
create_monitor () {
  \cat > "$BASE/monitor.sh" <<EOT

  # create the monitor wrapper script once -- this is used by all job startup
  # scripts to actually run job.sh.  The script gets SAGA_PID as argument,
  # denoting the job to monitor.   The monitor will write 3 pids to a named pipe
  # (listened to by the wrapper):
  #
  #   rpid: pid of the actual job              (not exposed to user)
  #   mpid: pid of this monitor.sh instance    (== pid of process group for cancel)
  #   upid: mpid + unique postfix on pid reuse (== SAGA id)

  MPID=\$\$
  NOTIFICATIONS="$NOTIFICATIONS"

  # on reuse of process IDs, we need to generate new, unique derivations of the
  # job directory name.  That name is, by default, the job's rpid.  Id the job
  # dies and that rpid is reused, we don't want to remove the old dir (job state
  # may still be queried), so we append an (increasing) integer to that dirname,
  # i.e. that job id
  POST=0
  UPID="\$MPID.\$POST"
  DIR="$BASE/\$UPID"
  
  while test -d "\$DIR"
  do
    POST=\$((\$POST+1))
    UPID="\$MPID.\$POST"
    DIR="$BASE/\$UPID"
  done

  \\mkdir -p "\$DIR"

# exec 2>"\$DIR/monitor.trace"
# set -x 


  # FIXME: timestamp
  START=\`\\awk 'BEGIN{srand(); print srand()}'\`
  \\printf "START : \$START\n"  > "\$DIR/stats"
  \\printf "NEW \n"            >> "\$DIR/state"

  # create represents the job.  The 'exec' call will replace
  # the subshell instance with the job executable, leaving the I/O redirections
  # intact.
  \\touch  "\$DIR/in"
  \\printf "#!/bin/sh\n\n" > \$DIR/cmd
  \\printf "\$@\n"        >> \$DIR/cmd
  \\chmod 0700               \$DIR/cmd

  (
    \\printf  "RUNNING \\n"             >> "\$DIR/state"
    \\printf  "\$SAGA_PID:RUNNING: \\n" >> "\$NOTIFICATIONS"
    \\exec "\$DIR/cmd"   < "\$DIR/in" > "\$DIR/out" 2> "\$DIR/err"
  ) 1> /dev/null 2>/dev/null 3</dev/null &

  # the real job ID (not exposed to user)
  RPID=\$!

  echo \$RPID >> /tmp/l

  \\printf "RUNNING \\n" >> "\$DIR/state" # declare as running
  \\printf "\$RPID\\n"    > "\$DIR/rpid"  # real process  pid
  \\printf "\$MPID\\n"    > "\$DIR/mpid"  # monitor shell pid
  \\printf "\$UPID\\n"    > "\$DIR/upid"  # unique job    pid

  # signal the wrapper that job startup is done, and report job id
  \\printf "\$UPID\\n" >> "$BASE/fifo"
  
  # start monitoring the job
  while true
  do
    \\wait \$RPID
    retv=\$?

    # if wait failed for other reason than job finishing, i.e. due to
    # suspend/resume, then we need to wait again, otherwise we are done
    # waiting...
    if test -e "\$DIR/suspended"
    then
      \\rm -f "\$DIR/suspended"
      TIME=\`\\awk 'BEGIN{srand(); print srand()}'\`
      \\printf "SUSPEND: \$TIME\\n"        >> "\$DIR/stats"
      \\printf "\$SAGA_PID:SUSPENDED: \\n" >> "$NOTIFICATIONS"

      # need to wait again
      continue
    fi

    if test -e "\$DIR/resumed"
    then
      \\rm -f "\$DIR/resumed"
      TIME=\`\\awk 'BEGIN{srand(); print srand()}'\`
      \\printf "RESUME : \$TIME\\n"      >> "\$DIR/stats"
      \\printf "\$SAGA_PID:RUNNING: \\n" >> "$NOTIFICATIONS"

      # need to wait again
      continue
    fi

    TIME=\`\\awk 'BEGIN{srand(); print srand()}'\`
    \\printf "STOP   : \$TIME\\n"  >> "\$DIR/stats"

    # evaluate exit val
    \\printf "\$retv\\n" > "\$DIR/exit"

    test   "\$retv" -eq 0  && \\printf            "DONE   \\n" >> "\$DIR/state"
    test   "\$retv" -eq 0  || \\printf            "FAILED \\n" >> "\$DIR/state"

    test   "\$retv" -eq 0  && \\printf "\$SAGA_PID:DONE:\$retv   \\n" >> "\$NOTIFICATIONS"
    test   "\$retv" -eq 0  || \\printf "\$SAGA_PID:FAILED:\$retv \\n" >> "\$NOTIFICATIONS"


    # done waiting
    break
  done

  exit

EOT

}


# --------------------------------------------------------------------
#
# list all job IDs
#
cmd_monitor () {

  # 'touch' to make sure the file exists, and use '-n 0' so that we don't 
  # read old notifications'
  # NOTE: tail complains on inotify handle shortage, and then continues 
  #       by using pulling.  We redirect stderr to /dev/null -- lets pray 
  #       that we don't miss any other notifications... :/
  \touch        "$NOTIFICATIONS"
  \tail -f -n 0 "$NOTIFICATIONS" 2>/dev/null

  # if tail dies for some reason, make sure the shell goes down
  \printf "EXIT\n"
  ERROR="EXIT"
  true
}


# --------------------------------------------------------------------
#
# run a job in the background.  Note that the returned job ID is actually the
# pid of the shell process which wraps the actual job, monitors its state, and
# serves its I/O channels.  The actual job id is stored in the 'pid' file in the
# jobs working directory.
#
# Note that the actual job is not run directly, but via nohup.  Otherwise all
# jobs would be canceled as soon as this master script finishes...
#
# Note further that we perform a double fork, effectively turning the monitor
# into a daemon.  That provides a speedup of ~300 percent, as the wait in 
# cmd_run now will return very quickly (it just waits on the second fork).  
# We can achieve near same performance be removing the wait, but that will 
# result in one zombie per command, which sticks around as long as the wrapper 
# script itself lives.
#
# Note that the working directory is created on the fly.  As the name of the dir
# is the pid, it must be unique -- we thus purge whatever trace we find of an
# earlier directory of the same name.
#
#
# Known limitations:
#
# The script has a small race condition, between starting the job (the 'nohup'
# line), and the next line where the jobs now known pid is stored away.  I don't
# see an option to make those two ops atomic, or resilient against system
# failure - so, in worst case, you might get a running job for which the job id
# is not stored (i.e. not known).
#
# Also, the line after is when the job state is set to 'Running' -- we can't
# really do that before, but on failure, in the worst case, we might have a job
# with known job ID which is not marked as running.
#
# Bottom line: full disk will screw with state consistency -- which is no
# surprise really...

cmd_run () {

  # do a double fork to avoid zombies.  Use 'set -m' to force a new process
  # group for the monitor
  (
   ( set -m 
     /bin/sh "$BASE/monitor.sh" "$@" 
   ) 1>/dev/null 2>/dev/null 3</dev/null & exit
  )

  # we wait until the job was really started, and get its pid from the fifo
  \read -r SAGA_PID < "$BASE/fifo"

  # report the current state
  \tail -n 1 "$BASE/$SAGA_PID/state" || \printf "UNKNOWN\n"

  # return job id
  RETVAL="$SAGA_PID"

}


cmd_lrun () {
  # LRUN allows to run shell commands which span more than one line.
  CMD=""
  # need IFS to preserve white space,
  OLDIFS=$IFS
  IFS=
  while \read -r IN
  do
    if test "$IN" = "LRUN_EOT "
    then
      break
    fi
    CMD="$CMD$IN\n"
  done
  IFS=$OLDIFS
  cmd_run "$CMD"
}

# --------------------------------------------------------------------
#
# inspect job state
#
cmd_state () {
  verify_state $1 || return

  DIR="$BASE/$1"
  RETVAL=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`
  if test "$RETVAL" = ""
  then
    RETVAL=UNKNOWN
  fi
}


# --------------------------------------------------------------------
#
# retrieve job stats
#
cmd_stats () {
  # stats are only defined for jobs in some state
  verify_state $1 || return

  DIR="$BASE/$1"
  STATE=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`
  RETVAL="STATE : $STATE\n"
  RETVAL="$RETVAL\n`\cat $DIR/stats`\n"
}


# --------------------------------------------------------------------
#
# wait for job to finish.  Arguments are pid, and time to wait in seconds
# (forever by default).  FIXME: timeout not yet implemented
#
cmd_wait () {

  while true
  do
    cmd_state $1

    case "$RETVAL" in
      DONE      ) return ;;
      FAILED    ) return ;;
      CANCELED  ) return ;;
      NEW       )        ;;
      RUNNING   )        ;;
      SUSPENDED )        ;;
      UNKNOWN   )        ;;   # FIXME: should be an error?
      *         ) ERROR="NOK - invalid state '$RETVAL'"
                  return ;;  
    esac

    \sleep 1
  done
}


# --------------------------------------------------------------------
#
# get exit code
#
cmd_result () {
  verify_state $1 || return

  DIR="$BASE/$1"
  state=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`

  if test "$state" != "DONE" -a "$state" != "FAILED" -a "$state" != "CANCELED"
  then 
    ERROR="job $1 in incorrect state ($state != DONE|FAILED|CANCELED)"
    return
  fi

  if ! test -r "$DIR/exit"
  then
    ERROR="job $1 in incorrect state -- no exit code available"
  fi

  RETVAL=`\cat "$DIR/exit"`
}


# --------------------------------------------------------------------
#
# suspend a running job
#
cmd_suspend () {
  verify_state $1 || return
  verify_pid   $1 || return

  DIR="$BASE/$1"
  state=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`
  rpid=`\cat "$DIR/rpid"`

  if ! test "$state" = "RUNNING"
  then
    ERROR="job $1 in incorrect state ($state != RUNNING)"
    return
  fi

  \touch "$DIR/suspended"
  RETVAL=`/bin/kill -STOP $rpid 2>&1`
  ECODE=$?

  if test "$ECODE" = "0"
  then
    \printf "SUSPENDED \n" >>  "$DIR/state"
    \printf "$state \n"    >   "$DIR/state.susp"
    RETVAL="$1 suspended"
  else
    \rm -f   "$DIR/suspended"
    ERROR="suspend failed ($ECODE): $RETVAL"
  fi

}


# --------------------------------------------------------------------
#
# resume a suspended job
#
cmd_resume () {
  verify_state $1 || return
  verify_pid   $1 || return

  DIR="$BASE/$1"
  state=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`
  rpid=`\cat "$DIR/rpid"`

  if ! test "$state" = "SUSPENDED"
  then
    ERROR="job $1 in incorrect state ($state != SUSPENDED)"
    return
  fi

  \touch   "$DIR/resumed"
  RETVAL=`/bin/kill -CONT $rpid 2>&1`
  ECODE=$?

  if test "$ECODE" = "0"
  then
    test -s "$DIR/state.susp" || \printf "RUNNING \n" >  "$DIR/state.susp"
    \cat    "$DIR/state.susp"                         >> "$DIR/state"
    \rm  -f "$DIR/state.susp"
    RETVAL="$1 resumed"
  else
    \rm  -f "$DIR/resumed"
    ERROR="resume failed ($ECODE): $RETVAL"
  fi

}


# --------------------------------------------------------------------
#
# kill a job, and set state to canceled
#
cmd_cancel () {
  verify_state $1 || return
  verify_pid   $1 || return

  DIR="$BASE/$1"


  rpid=`\cat "$DIR/rpid"`
  mpid=`\cat "$DIR/mpid"`

  # first kill monitor, so that it does not interfer with state management
  /bin/kill -TERM $mpid 2>/dev/null
  /bin/kill -KILL $mpid 2>/dev/null

  # now make sure that job did not reach final state before monitor died
  state=`\grep -e ' $' "$DIR/state" | \tail -n 1 | \tr -d ' '`
  if test "$state" = "FAILED" -o "$state" = "DONE" -o "$state" = "CANCELED"
  then
    ERROR="job $1 in incorrect state ('$state' = 'DONE|FAILED|CANCELED')"
    return
  fi

  # now kill the job process group, and to be sure also the job shell
  /bin/kill -TERM $KILL_DASHES -$mpid # this is the important one...
  /bin/kill -KILL $KILL_DASHES -$mpid 2>/dev/null
  /bin/kill -TERM               $rpid 2>/dev/null
  /bin/kill -KILL               $rpid 2>/dev/null

  # FIXME: how can we check for success?  ps?
  \printf "CANCELED \n" >> "$DIR/state"
  RETVAL="$1 canceled"
}


# --------------------------------------------------------------------
#
# feed given string to job's stdin stream
#
cmd_stdin () {
  verify_in $1 || return

  DIR="$BASE/$1"
  shift
  \printf "$@" >> "$DIR/in"
  RETVAL="stdin refreshed"
}


# --------------------------------------------------------------------
#
# print encoded string of job's stdout
#
cmd_stdout () {
  verify_out $1 || return

  DIR="$BASE/$1"
  RETVAL=`cat "$DIR/out" | od -t x1 -A n #| cut -c 2- | tr -d ' \n'`
}


# --------------------------------------------------------------------
#
# print uuencoded string of job's stderr
#
cmd_stderr () {
  verify_err $1 || return

  DIR="$BASE/$1"
  RETVAL=`cat "$DIR/err" | od -t x1 -A n #| cut -c 2- | tr -d ' \n'`
}


# --------------------------------------------------------------------
#
# list all job IDs
#
cmd_list () {
  RETVAL=`(\cd "$BASE" ; \ls -C1 -d */ 2>/dev/null) | \cut -f 1 -d '/'`
}


# --------------------------------------------------------------------
#
# purge working directories of given jobs 
# default (no job id given): purge all final jobs older than 1 day
#
cmd_purge () {

  if ! test -z "$1"
  then
    DIR="$BASE/$1"
    \rm -rf "$DIR"
    RETVAL="purged $1"
  else
    for d in `\grep -l -e 'DONE' -e 'FAILED' -e 'CANCELED' "$BASE"/*/state 2>/dev/null`
    do
      dir=`dirname "$d"`
      id=`basename "$dir"`
      \find  "$BASE/$id"      -type f -mtime +1 -print | xargs -n 100 rm -f
      \rmdir "$BASE/$id"      >/dev/null 2>&1
      \find  "$NOTIFICATIONS" -type f -mtime +1 -print | xargs -n 100 rm -f
      \touch "$NOTIFICATIONS"
    done
    RETVAL="purged finished jobs"
  fi
}


# --------------------------------------------------------------------
#
# purge tmp files for bulks etc.
#
cmd_purge_tmps () {

  \rm -f "$BASE"/bulk.*
  \rm -f "$BASE"/idle.*
  \rm -f "$BASE"/quit.*
  \find  "$BASE" -type d -mtime +30 -print | xargs -n 100 \rm -rf 
  \find  "$BASE" -type f -mtime +30 -print | xargs -n 100 \rm -f 
  RETVAL="purged tmp files"
}


# --------------------------------------------------------------------
#
# quit this script gracefully
#
cmd_quit () {

  if test "$1" = "TIMEOUT"
  then
    \printf "IDLE TIMEOUT\n"
    \touch "$BASE/timed_out.$$"
    EXIT_VAL=2
  else
    \touch "$BASE/quit.$$"
  fi

  # kill idle checker
  /bin/kill $1 >/dev/null 2>&1
  \rm -f "$BASE/idle.$$"

  # clean bulk file and other temp files
  \rm -f bulk.$$

  # restore shell echo
  \stty echo    >/dev/null 2>&1
  \stty echonl  >/dev/null 2>&1

  exit $EXIT_VAL
}


# --------------------------------------------------------------------
#
# main even loop -- wait for incoming command lines, and react on them
#
listen() {

  # report our own pid
  if ! test -z $1; then
    \printf "PID: $$\n" # FIXME: this should be $1
  fi

  # interprete new base dir
  if ! test -z $2; then
    BASE="$2"
    NOTIFICATIONS="$BASE/notifications"
  fi

  # make sure the base has a monitor script....
  create_monitor


  # we need our home base cleaned
  test -d "$BASE" || \mkdir -p  "$BASE"  || exit 1
  \touch  "$BASE/bulk.$$"
  \rm  -f "$BASE/bulk.$$"
  \touch  "$BASE/bulk.$$"

  # set up monitoring fifo
  if ! test -f "$NOTIFICATIONS"
  then
    \touch "$NOTIFICATIONS"
  fi

  # make sure we get killed when idle
  idle_checker $$ 1>/dev/null 2>/dev/null 3</dev/null &
  IDLE=$!

  # create fifo to communicate with the monitors
  \rm -f  "$BASE/fifo"
  \mkfifo "$BASE/fifo"

  # prompt for commands...
  \printf "PROMPT-0->\n"

  # and read those from stdin
  OLDIFS=$IFS
  IFS=
  while \read -r CMD ARGS
  do

    # check if we start or finish a bulk
    case $CMD in
      BULK     ) IN_BULK=1
                 BULK_ERROR="OK"
                 BULK_EXITVAL="0"
                 ;;
      BULK_RUN ) IN_BULK=""
                 \printf "BULK_EVAL\n" >> "$BASE/bulk.$$"
                 ;;
      *        ) \echo   "$CMD $ARGS"  >> "$BASE/bulk.$$"
                 ;;
    esac

    if ! test -z "$IN_BULK"
    then
      # continue to collect bulk commands
      continue
    fi

    # no more bulk collection (if there ever was any) -- execute the collected
    # command lines.
    IFS=$OLDIFS
    while \read -r CMD ARGS
    do

      # reset err state for each command
      ERROR="OK"
      RETVAL=""

      # simply invoke the right function for each command, or complain if command
      # is not known
      case $CMD in
        MONITOR   ) cmd_monitor "$ARGS"  ;;
        RUN       ) cmd_run     "$ARGS"  ;;
        LRUN      ) cmd_lrun    "$ARGS"  ;;
        SUSPEND   ) cmd_suspend "$ARGS"  ;;
        RESUME    ) cmd_resume  "$ARGS"  ;;
        CANCEL    ) cmd_cancel  "$ARGS"  ;;
        RESULT    ) cmd_result  "$ARGS"  ;;
        STATE     ) cmd_state   "$ARGS"  ;;
        STATS     ) cmd_stats   "$ARGS"  ;;
        WAIT      ) cmd_wait    "$ARGS"  ;;
        STDIN     ) cmd_stdin   "$ARGS"  ;;
        STDOUT    ) cmd_stdout  "$ARGS"  ;;
        STDERR    ) cmd_stderr  "$ARGS"  ;;
        LIST      ) cmd_list    "$ARGS"  ;;
        PURGE     ) cmd_purge   "$ARGS"  ;;
        QUIT      ) cmd_quit    "$IDLE"  ;;
        NOOP      ) ERROR="NOOP"         ;;
        BULK_EVAL ) ERROR="$BULK_ERROR"
                    RETVAL="BULK COMPLETED"
                    test "$ERROR" = OK || false
                    ;;
        *         ) RETVAL=$($CMD $ARGS 2>&1) || ERROR="NOK - command '$CMD' failed" ;;
      esac

      EXITVAL=$?

      # the called function will report state and results in 'ERROR' and 'RETVAL'
      if test "$ERROR" = "OK"; then
        \printf "OK\n"
        \printf "$RETVAL\n"
      elif test "$ERROR" = "NOOP"; then
        # nothing
        true
      elif test "$ERROR" = "EXIT"; then
        exit
      else
        \printf "ERROR\n"
        \printf "$ERROR\n"
        \printf "$RETVAL\n"
        BULK_ERROR="NOK - bulk error '$ERROR'"  # a single error spoils the bulk
        BULK_EXITVAL="$EXITVAL"
      fi

      # we did hard work - make sure we are not getting killed for idleness!
      \rm -f "$BASE/idle.$$"

      # well done - prompt for next command (even in bulk mode, for easier
      # parsing and EXITVAL communication)
      \printf "PROMPT-$EXITVAL->\n"

    # closing thye read loop for the bulk data file
    done < "$BASE/bulk.$$"

    # empty the bulk data file
    \rm -f "$BASE/bulk.$$"

    # next main loop read needs IFS reset again
    OLDIFS=$IFS
    IFS=

  done
}


# --------------------------------------------------------------------
#
# run the main loop -- that will live forever, until a 'QUIT' command is
# encountered.
#
# The first arg to wrapper.sh is the id of the spawning shell, which we need to
# report, if given
#
\stty -echo   2> /dev/null
\stty -echonl 2> /dev/null

# FIXME: this leads to timing issues -- disable for benchmarking
if test "$PURGE_ON_START" = "True"
then
  cmd_purge
  cmd_purge_tmps
fi

listen $*
#
# --------------------------------------------------------------------

# vim: tabstop=2 expandtab shiftwidth=2 softtabstop=2

