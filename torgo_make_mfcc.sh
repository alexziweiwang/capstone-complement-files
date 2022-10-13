!/bin/bash 

# Copyright 2012  Johns Hopkins University (Author: Daniel Povey)
# Cristina Espana-Bonet
# Adapted to deal with two different time shifts (larger for dysarthric speakers)
# In case of data with segments it must be further modified
# Apache 2.0
# To be run from .. (one directory up from here)
# see ../run.sh for example

# Begin configuration section.
nj=8
cmd=!bash /content/torgo_asr/run.pl
mfcc_config=/content/torgo_asr/conf/mfcc.conf
mfcc_config_dys=/content/torgo_asr/conf/mfcc_dysarthric.conf  # can of course also be conf/mfcc.conf
compress=true
write_utt2num_frames=false  # if true writes utt2num_frames
# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
   echo "Usage: $0 [options] <data-dir> [<log-dir> [<path-to-mfccdir>]]";
   echo "e.g.: $0 data/train exp/make_mfcc/train mfcc"
   echo "options: "
   echo "  --mfcc-config <config-file>                      # config passed to compute-mfcc-feats "
   echo "  --mfcc-config-dys <config-file>                  # config passed to compute-mfcc-feats "
   echo "                                                   # for dysarthric speakers"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --write-utt2num-frames <true|false>     # If true, write utt2num_frames file."
   exit 1;
fi

data=$1
if [ $# -ge 2 ]; then
  logdir=$2
else
  logdir=$data/log
fi
if [ $# -ge 3 ]; then
  mfccdir=$3
else
  mfccdir=$data/data
fi

# make $mfccdir an absolute pathname.
mfccdir=`perl -e '($dir,$pwd)= @ARGV; if($dir!~m:^/:) { $dir = "$pwd/$dir"; } print $dir; ' $mfccdir ${PWD}`

# use "name" as part of name of the archive.
name=`basename $data`

mkdir -p $mfccdir || exit 1;
mkdir -p $logdir || exit 1;

if [ -f $data/feats.scp ]; then
  mkdir -p $data/.backup
  echo "$0: moving $data/feats.scp to $data/.backup"
  mv $data/feats.scp $data/.backup
fi

scp=$data/wav.scp
utt2spk=$data/utt2spk

required="$scp $mfcc_config $mfcc_config_dys"

for f in $required; do
  if [ ! -f $f ]; then
    echo "make_mfcc.sh: no such file $f"
    exit 1;
  fi
done
#Utils package
./validate_data_dir.sh --no-text --no-feats $data || exit 1;

if [ -f $data/spk2warp ]; then
  echo "$0 [info]: using VTLN warp factors from $data/spk2warp"
  vtln_opts="--vtln-map=ark:$data/spk2warp --utt2spk=ark:$data/utt2spk"
elif [ -f $data/utt2warp ]; then
  echo "$0 [info]: using VTLN warp factors from $data/utt2warp"
  vtln_opts="--vtln-map=ark:$data/utt2warp"
fi

for n in $(seq $nj); do
  # the next command does nothing unless $mfccdir/storage/ exists, see
  # utils/create_data_link.pl for more info.
  #Utils package
  # utils/create_data_link.pl $mfccdir/raw_mfcc_$name.$n.ark

  ./create_data_link.pl $mfccdir/raw_mfcc_$name.$n.ark
done


if $write_utt2num_frames; then
  write_num_frames_opt="--write-num-frames=ark,t:$logdir/utt2num_frames.JOB"
else
  write_num_frames_opt=
fi


if [ -f $data/segments ]; then
  echo "$0 [info]: segments file exists: using that."

  split_segments=""
  for n in $(seq $nj); do
    split_segments="$split_segments $logdir/segments.$n"
  done
 
 #Utils package
  ./split_scp.pl $data/segments $split_segments || exit 1;
  rm $logdir/.error 2>/dev/null

  $cmd JOB=1:$nj $logdir/make_mfcc_${name}.JOB.log \
    extract-segments scp,p:$scp $logdir/segments.JOB ark:- \| \
    compute-mfcc-feats $vtln_opts --verbose=2 --config=$mfcc_config ark:- ark:- \| \
    copy-feats --compress=$compress ark:- \
      ark,scp:$mfccdir/raw_mfcc_$name.JOB.ark,$mfccdir/raw_mfcc_$name.JOB.scp \
     || exit 1;

else
  echo "$0: [info]: no segments file exists: assuming wav.scp indexed by utterance."
  split_scps=""
  for n in $(seq $nj); do
      split_scps="$split_scps $logdir/wav_${name}.$n.scp"
  done

  # We divide according to each speaker, 8
  if [ $nj -eq 8 ] ; then
     utils/split_scp.pl --utt2spk=$utt2spk  $scp $split_scps || exit 1;
  else
     utils/split_scp.pl $scp $split_scps || exit 1;
  fi 

  for JOB in $(seq $nj); do
     line=$(<$logdir/wav_${name}.$JOB.scp)
     # Select config based on whether the speaker is dysarthric or not.
     if [[ $line =~ M0.* || $line =~ F0.*  ]]; then
        config=$mfcc_config_dys
     else
        config=$mfcc_config
     fi

     ($cmd $logdir/make_mfcc_${name}.$JOB.log \
       compute-mfcc-feats  $vtln_opts --verbose=2 --config=$config \
        scp,p:$logdir/wav_${name}.$JOB.scp ark:- \| \
        copy-feats --compress=$compress ark:- \
        ark,scp:$mfccdir/raw_mfcc_$name.$JOB.ark,$mfccdir/raw_mfcc_$name.$JOB.scp \
      || exit 1;)&
  done
  wait;
fi


if [ -f $logdir/.error.$name ]; then
  echo "Error producing mfcc features for $name:"
  tail $logdir/make_mfcc_${name}.1.log
  exit 1;
fi

# concatenate the .scp files together.
for n in $(seq $nj); do
  cat $mfccdir/raw_mfcc_$name.$n.scp || exit 1;
done > $data/feats.scp

if $write_utt2num_frames; then
  for n in $(seq $nj); do
    cat $logdir/utt2num_frames.$n || exit 1;
  done > $data/utt2num_frames || exit 1
  rm $logdir/utt2num_frames.*
fi

rm $logdir/wav_${name}.*.scp  $logdir/segments.* 2>/dev/null

nf=`cat $data/feats.scp | wc -l` 
nu=`cat $data/utt2spk | wc -l` 
if [ $nf -ne $nu ]; then
  echo "It seems not all of the feature files were successfully processed ($nf != $nu);"
  echo "consider using utils/fix_data_dir.sh $data"
fi

if [ $nf -lt $[$nu - ($nu/20)] ]; then
  echo "Less than 95% the features were successfully generated.  Probably a serious error."
  exit 1;
fi

echo "Succeeded creating MFCC features for $name"
