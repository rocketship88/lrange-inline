# bench.tcl - usage: tclsh bench.tcl ?reps?
# Times [lrange] forms in compiled procs; best of 7 runs, ns/call.
# 'var-var-cmd' calls lrange through a variable, so it always takes the
# ordinary command path: it is what 'var-var' cost before listRange existed.
set N [expr {$argc ? [lindex $argv 0] : 2000000}]
proc best {script} {
    set b {}
    for {set k 0} {$k < 7} {incr k} {
	set t [lindex [time $script 1] 0]
	if {$b eq {} || $t < $b} {set b $t}
    }
    set b
}
set l {a b c d e f g h i j}
set cases {
    literal	{lrange $l 1 3}
    var-var	{lrange $l $i $j}
    var-var-cmd	{$c $l $i $j}
    var-end	{lrange $l $i end}
    end-minus-n	{lrange $l 1 end-$n}
    int-arith	{lrange $l 1 [expr {[llength $l]-$n-1}]}
}
puts "[info patchlevel]  N=$N"
foreach {name body} $cases {
    proc bench_$name {l i j n N} "set c lrange; for {set k 0} {\$k < \$N} {incr k} {$body}"
    set us [best [list bench_$name $l 1 3 1 $N]]
    puts [format "%-12s %8.1f ns/call   %s" $name [expr {$us*1000.0/$N}] $body]
}
