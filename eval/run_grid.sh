#!/bin/bash
# Documentation
# This bash file takes three inputs. The first argument (nfs_home) is the path to the nfs home directory.
# The second one (python_bin) is the path to the python bin folder.
# The last argument (logs_subfolder) is the path to the logs folder with respect to the nfs home directory.
#
# The nfs home directory should contain the code of this framework stored in $nfs_home/decentralizepy and a folder
# called configs which contains the file 'ip_addr_6Machines.json'
# The python bin folder needs to include all the dependencies of this project including crudini.
# The results will be stored in $nfs_home/$logs_subfolder
# Each of the experiments will be stored in its own folder inside the logs_subfolder. The folder of the experiment
# starts with the last part of the config name, i.e., for 'config_celeba_topkacc.ini' it will start with topkacc.
# The name further includes the learning rate, rounds and batchsize as well as the exact date at which the experiment
# was run.
# Example: ./run_grid.sh  /mnt/nfs/wigger /mnt/nfs/wigger/anaconda3/envs/sacs39/bin /logs/celeba
#
# Additional requirements:
# Each node needs a folder called 'tmp' in the user's home directory
#
# Note:
# - The script does not change the optimizer. All configs are writen to use Adam.
#   For SGD these need to be changed manually
# - The script will set '--test_after' and '--train_evaluate_after' to comm_rounds_per_global_epoch, i.e., the eavaluation
#   on the train set and on the test set is carried out every global epoch.
# - The '--reset_optimizer' option is set to 0, i.e., the optimizer is not reset after a communication round (only
#   relevant for Adams and other optimizers with internal state)
#
# Addapting the script to other datasets:
# Change the variable 'dataset_size' to reflect the data sets size.
#
# Known issues:
# - If the script is started at the very end of a minute then there is a change that two folders are created as not all
#   machines may start running the script at the exact same moment.

nfs_home=$1
python_bin=$2
logs_subfolder=$3
decpy_path=$nfs_home/decentralizepy/eval
cd $decpy_path

env_python=$python_bin/python3
graph=192_regular.edges
config_file=~/tmp/config.ini
procs_per_machine=32
machines=6
global_epochs=25
eval_file=testing.py
log_level=INFO

ip_machines=$nfs_home/configs/ip_addr_6Machines.json

m=`cat $ip_machines | grep $(/sbin/ifconfig ens785 | grep 'inet ' | awk '{print $2}') | cut -d'"' -f2`
export PYTHONFAULTHANDLER=1

# Base configs for which the gird search is done
tests=("step_configs/config_celeba_sharing.ini")
# Learning rates to test
lrs=( "0.001" "0.0001" "0.0001")
# Batch sizes to test
batchsize=("8" "16")
# The number of communication rounds per global epoch to test
comm_rounds_per_global_epoch=("1" "10" "100")
procs=`expr $procs_per_machine \* $machines`
echo procs: $procs
# Celeba has 63741 samples
dataset_size=63741
# Calculating the number of samples that each user/proc will have on average
samples_per_user=`expr $dataset_size / $procs`
echo samples per user: $samples_per_user

for b in "${batchsize[@]}"
do
  echo batchsize: $b
  for r in "${comm_rounds_per_global_epoch[@]}"
  do
    echo communication rounds per global epoch: $r
    # calculating how many batches there are in a global epoch for each user/proc
    batches_per_epoch=$(($samples_per_user / $b))
    echo batches per global epoch: $batches_per_epoch
    # the number of iterations in 25 global epochs
    iterations=$($env_python -c "from math import floor; print($batches_per_epoch * $global_epochs) if $r >= $batches_per_epoch else print($global_epochs * $r)")
    echo iterations: $iterations
    # calculating the number of batches each user/proc uses per communication step (The actual number may be a float, which we round down)
    batches_per_comm_round=$($env_python -c "from math import floor; x = floor($batches_per_epoch / $r); print(1 if x==0 else x)")
    # since the batches per communication round were rounded down we need to change the number of iterations to reflect that
    new_iterations=$($env_python -c "from math import floor; x = floor($batches_per_epoch / $r); y = floor((($batches_per_epoch / $r) - x +1)*$iterations); print($iterations if x==0 else y)")
    echo batches per communication round: $batches_per_comm_round
    echo corrected iterations: $new_iterations
    for lr in "${lrs[@]}"
    do
      for i in "${tests[@]}"
      do
        echo $i
        IFS='_' read -ra NAMES <<< $i
        IFS='.' read -ra NAME <<< ${NAMES[-1]}
        log_dir=$nfs_home$logs_subfolder/${NAME[0]}:lr=$lr:r=$r:b=$b:$(date '+%Y-%m-%dT%H:%M')/machine$m
        echo results are stored in: $log_dir
        mkdir -p $log_dir
        cp $i $config_file
        # changing the config files to reflect the values of the current grid search state
        $python_bin/crudini --set $config_file COMMUNICATION addresses_filepath $ip_machines
        $python_bin/crudini --set $config_file OPTIMIZER_PARAMS lr $lr
        $python_bin/crudini --set $config_file TRAIN_PARAMS rounds $batches_per_comm_round
        $python_bin/crudini --set $config_file TRAIN_PARAMS batch_size $b
        $env_python $eval_file -ro 0 -tea $r -ld $log_dir -mid $m -ps $procs_per_machine -ms $machines -is $new_iterations -gf $graph -ta $r -cf $config_file -ll $log_level
        echo $i is done
        sleep 1
        echo end of sleep
      done
    done
  done
done
#

