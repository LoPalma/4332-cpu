perl -pe '
if(/(\d+)\s*=>\s*enc_imm\((\d+),\s*(\d+)\)/){
    $n=$1; $d=$2; $i=$3;
    $_ = "$n => enc(OP_LOADIMM, $d),\n".($n+1)." => x\"".sprintf("%04X",$i)."\",\n";
}
' cpu_tb.vhd