#!/sbin/sh
# patchbootimg.sh
# 2010-06-24 Firerat
# patch boot.img with custom partition table
# Credits lbcoder
# http://forum.xda-developers.com/showthread.php?t=704560
#
# https://github.com/Firerat/CustomMTD

version=1.5.9-Alpha5
##

readdmesg ()
{
$dmesg|awk '/0x.+: "/ {sub(/-/," ");gsub(/"/,"");gsub(/0x/,"");printf $6" 0x"toupper ($3)" 0x"toupper ($4)"\n"}' > $dmesgmtdpart

# need a sanity check, what if recovery had been running for ages and the dmesg buffer had been filled?
for sanity in misc recovery boot system cache userdata;do
    if [ `grep -q $sanity $dmesgmtdpart;echo $?` = "0" ];
    then
        sain=y
    else
        sain=n
        break
    fi
done
# collecting the mtd driver from dmesg now so need to bail if none
nandtype=`$dmesg|awk '/Creating/ && /MTD partitions on/ {print $NF}'|sed s/\"//g`
if [ "$nandtype" = "" ];
then
    echo "Error1=nand type not found" >> $logfile
    echo "Error2=try again after fresh reboot" >> $logfile
    echo "success=false" >> $logfile
    exit
fi
if [ "$sain" = "n" ];
then
    echo "Error1=Error $sanity not found in dmesg" >> $logfile
    echo "success=false" >> $logfile
    exit
else
    for partition in `cat $dmesgmtdpart|awk '{print $1}'`;do
        eval ${partition}StartHex=`awk '/'$partition'/ {print $2}' $dmesgmtdpart`
        eval ${partition}EndHex=`awk '/'$partition'/ {print $3}' $dmesgmtdpart`
    done

    # figure out the partition order of system cache and userdata
    for partition in system cache userdata;do
        eval StartHex=\$${partition}StartHex
        for part in `cat $dmesgmtdpart|awk '{print $1}'`;do
            if [ "$StartHex" = "`awk '/'$part'/ {print $3}' $dmesgmtdpart`" ];
            then
                eval ${partition}StartsAtEndOf=$part
                break
            fi
        done
    done

    # now check if system, cache and userdata are consecutive
    if [ "$cacheStartsAtEndOf" = "system" -a "$userdataStartsAtEndOf" = "cache" ];
    then
        consecutive=yes
        exclude="system|cache|userdata"
    else
        if [ "$userdataStartsAtEndOf" = "system" ];
        then
            echo "Error1=none consecutive partitions" >> $logfile
            echo "Error2=detected, can not proceed" >> $logfile
            echo "success=false" >> $logfile
            exit
            consecutive=SD
            exclude="system|userdata"
        else
            echo "Error1=none consecutive partitions" >> $logfile
            echo "Error2=detected, can not proceed" >> $logfile
            echo "success=false" >> $logfile
            exit
            consecutive=CD
            exclude="cache|userdata"
        fi
    fi
    #Get resizable nand size ( mb )
    SCD_Total=0
    for partition in system cache userdata;do
        eval StartHex=\$${partition}StartHex
        eval EndHex=\$${partition}EndHex
        eval Sizebytes=`expr $(printf %d $EndHex) - $(printf %d $StartHex)`
        eval ${partition}SizeMBytes=`echo |awk '{printf "%.3f", '$Sizebytes' / 1048576}'`
        eval SizeMB=\$${partition}SizeMBytes
        partition=`echo $partition|sed s/user//`
echo $partition
        echo|awk '{printf "%s%s%s%-9s%s%9.3f %s","Orig_","'$partition'","Size=","'$partition'","=",'$SizeMB',"MB\n"}' >> $logfile
    done
    SCD_Total=`echo|awk '{printf "%g",'$systemSizeMBytes' + '$cacheSizeMBytes' + '$userdataSizeMBytes' }'`
    for partition in `cat $dmesgmtdpart|awk '!/'$exclude'/ {print $1}'`;do
        eval StartHex=\$${partition}StartHex
        eval EndHex=\$${partition}EndHex
        eval ${partition}SizeKBytes=`expr \( $(printf %d $EndHex) - $(printf %d $StartHex) \) \/ 1024 `
        eval SizeKBytes=\$${partition}SizeKBytes
        if [ "$partition" = "cache" -a "$consecutive" = "SD" ];
        then
            partition=system
        fi
        eval ${partition}CL="`echo \"${SizeKBytes}K@${StartHex}\(${partition}\)\"`"
    done
fi
return
}

readconfig ()
{
if [ ! -e $config ];
then
    writeconfig
fi
if [ "`awk -Fconfigversion\= '$0 = $2' $config|awk '$0 = $1'`" -lt "159" ];
then
    cp $config `dirname ${config}`/`basename $config .txt`-`date +%Y-%m-%d-%H%S-%Z`.txt
    writeconfig
fi
sed s/$// $config > /tmp/`basename $config`
. /tmp/`basename $config`

if [ "$systemMB" = "0" ];
then
    removecmtd
fi

# need at least 1.5mb cache for recovery to not complain
# Meh, need whole numbers
if [ "`echo|awk '{printf "%d" '$cacheMB' * 10}'`" -lt "15" -o "$cacheMB" = "" ];
then
    cacheMB=1.5
fi

# make sure we are sizing in units of 128k ( 0.125 MB )
for UserSize in $systemMB $cacheMB;do
    expr $(echo|awk '{printf "%g", '$UserSize' / 0.125}') \* 1
    if [ "$?" != "0" ];
    then
        echo "Error1=$UserSize not divisable by 0.125" >> $logfile
        echo "success=false" >> $logfile
        exit
    fi
done

if [ "$SPL" = "`awk -Fandroidboot.bootloader= '$0 = $2' /proc/cmdline|awk '$0 = $1'`" ];
then
    CLInit="$CLInit"
else
    CLInit="androidboot.bootloader=$SPL $CLInit"
fi

return
}
writeconfig ()
{
echo "# CustomMTD config" > $config
echo "# This file should be saved as plain text" > $config
echo "# " > $config
echo "# please *do not* edit configversion!" >> $config
echo "configversion=159" >> $config
echo "#####" >> $config
echo "systemMB=$systemSizeMBytes # system size in mb ( increments of 0.125 mb )" >> $config
echo "cacheMB=$cacheSizeMBytes # cache size in mb ( increments of 0.125 mb )" >> $config
echo "systemfree=2 # used by Optimise feature" >> $config
echo "cachefree=2 # used by Optimise feature" >> $config
echo "# Optimise is not turned on yet"  >> $config
echo "# but when it is, it will set the system and cache size based on the installed ROM"
echo "# the system and cache free values are the amount of free space which will be left"
echo "# 1 = 128k , 2 = 256k , 4 = 512k" >> $config
echo "# yeap, you figured it out, 8 = 1024k ( or 1 mb )" >> $config
echo "# NOTE, depending on your recovery version you may see slightly more" >> $config
echo "# free space in the ROM, as its yaffs2 tends to be more efficient with space" >> $config
echo "mindatasize=50 # don't patch recovery if data size will be less than this" >> $config
echo "#####" >> $config
SPL=`awk -Fandroidboot.bootloader= '$0 = $2' /proc/cmdline|awk '$0 = $1'`
SpoofedSPL=`awk -Fandroidboot.bootloader= '$0 = $3' /proc/cmdline|awk '$0 = $1'`
if [ "$SpoofedSPL" = "" -o "$SpoofedSPL" = "$SPL" ];
then
    SPL=$SPL
else
    SPL=$SpoofedSPL
fi
echo "SPL=$SPL # use this to 'spoof' your SPL version" >> $config
echo "# NOTE: SPL spoofing tricks a ROM's assert checks into" >> $config
echo "# thinking you have a different SPL to the one you have" >> $config
echo "# do not complain if things don't work out" >> $config
echo "# ( tbh, you probably don't need it, so leave it alone ;)" >> $config
echo "#####" >> $config
LastRecoverymd5sum=`md5sum /dev/mtd/$(awk -F: '/recovery/ {print $1}' $mtdpart)ro|awk '{print $1}'`
echo "# md5sum of the last recovery flashed by customMTD" >> $config
echo "recoverymd5=$LastRecoverymd5sum" >> $config
busybox unix2dos $config

echo "Info1=New config written to :" >> $logfile
echo "Info2=$config" >> $logfile

return
}
checksizing ()
{
usertotal=`echo|awk '{printf "%.3f",'$systemMB' + '$cacheMB'}'`
userdatasize=`echo|awk '{printf "%.3f",'$SCD_Total' - '$usertotal'}'`
# check if user wants to override min data size
if [ "$mindatasize" = "" ];
then
    # a freshly installed ROM should still boot with 50mb data
    # However trickery to get things on to /sd-ext may be required
    mindatasize=50
fi

if [ "`echo|awk '{printf "%d", '$userdatasize'}'`" -lt "$mindatasize" ];
then
    echo "Error1=data will be less than ${mindatasize}mb" >> $logfile
    echo "Error2=if you wish to skip this check" >> $logfile
    echo "Error3=change \"mindatasize\" in `basename $config`" >> $logfile
    echo "Success=false" >> $logfile
    exit
fi
return
}

CreateCMDline ()
{
systemStartHex=`awk '/system/ { print $2 }' $dmesgmtdpart`
systemStartBytes=`printf %d $(awk '/system/ { print $2 }' $dmesgmtdpart)`
systemSizeKBytes=`echo|awk '{printf "%d",'$systemMB' * 1024}'`
systemBytes=`echo|awk '{printf "%f",'$systemSizeKBytes' * 1024}'`
systemCL="${systemSizeKBytes}k@${systemStartHex}(system)"

cacheSizeKBytes=`echo|awk '{printf "%d",'$cacheMB' * 1024}'`
cacheBytes=`echo|awk '{printf "%f",'$cacheSizeKBytes' * 1024}'`
if [ "$consecutive" = "SD" ];
then
    cacheStartHex=`echo|awk '{printf "%X",'$systemStartBytes'}'`
elif [ "$consecutive" = "CD" ];
then
    cacheStartHex=`awk '/cache/ {printf "%X",$2 }' $dmesgmtdpart`
else
    cacheStartBytes=`echo|awk '{printf "%f",'$systemStartBytes' + '$systemBytes'}'`
    cacheStartHex=`echo|awk '{printf "%X",'$cacheStartBytes'}'`
fi
cacheCL="${cacheSizeKBytes}k@0x${cacheStartHex}(cache)"

dataStartBytes=`echo|awk '{printf "%f",'$cacheStartBytes' + '$cacheBytes'}'`
dataStartHex=`echo|awk '{printf "%X",'$dataStartBytes'}'`
dataSizeBytes=`echo|awk '{printf "%f",'$(printf '%d' ${userdataEndHex})' - '$dataStartBytes'}'`
dataSizeKBytes=`echo|awk '{printf "%d",'$dataSizeBytes' / 1024}'`
userdataCL="${dataSizeKBytes}k@0x${dataStartHex}(userdata)"

buildCMDline="${CLInit} mtdparts=$nandtype"
for partition in `cat $dmesgmtdpart|awk '{print $1}'`;do
    eval CL=\$${partition}CL
    buildCMDline="${buildCMDline}${CL},"
done
KCMDline="`echo $buildCMDline|sed s/,\$//`"

for MTDPart in system cache data;do
    eval SizeKB=\$${MTDPart}SizeKBytes
    eval SizeMB=`echo|awk '{printf "%.3f",'$SizeKB'/1024}'`
    echo|awk '{printf "%s%s%s%-9s%s%9.3f %s","New_","'$MTDPart'","Size=","'$MTDPart'","=",'$SizeMB',"MB\n"}' >> $logfile
done
return
}

GetCMDline ()
{
KCMDline="mtdparts`cat /proc/cmdline|awk -Fmtdparts '{print $2}'`"
if [ "$KCMDline" = "mtdparts" ];
then
    KCMDline=""
fi
    for MTDPart in system cache userdata;do
        SizeMB=$(printf %d `awk '/'${MTDPart}'/ {print "0x"$2}' $mtdpart`|awk '{printf "%.3f", $1 / 1048576}')
        MTDPart=`echo $MTDPart|sed s/user//`
        echo|awk '{printf "%s%s%s%-9s%s%9.3f %s","New_","'$MTDPart'","Size=","'$MTDPart'","=",'$SizeMB',"MB\n"}' >> $logfile
    done
return
}

dumpimg ()
{
mtdblk=`awk -F: '/'$boot'/ {print $1}' $mtdpart`ro
$wkdir/unpackbootimg /dev/mtd/${mtdblk} $wkdir/
origcmdline=`awk '{gsub(/\ .\ /,"");sub(/mtdparts.+)/,"");sub(/androidboot.bootloader=.+\ /,"");print}' $wkdir/${mtdblk}-cmdline|awk '{$1=$1};1'`
return
}

flashimg ()
{
$1 $wkdir/mkbootimg --kernel $wkdir/${mtdblk}-zImage --ramdisk $wkdir/${mtdblk}-ramdisk.gz -o $wkdir/${boot}.img --cmdline "$origcmdline $KCMDline" --base `cat $wkdir/${mtdblk}-base`
$1 erase_image ${boot}
$1 flash_image ${boot} $wkdir/${boot}.img
if [ "$?" = "0" ];
then
    echo "success=true" >> $logfile
    if [ "$boot" = "recovery" ];
    then
        sed s/recoverymd5=.*/recoverymd5=`md5sum /dev/mtd/${mtdblk}|awk '{print $1}'`/ -i $config
        busybox unix2dos $config
    fi
    exit
else
    echo "Error1=Writing $boot failed" >> $logfile
    echo "Error2=Make sure you have an unlocked" >> $logfile
    echo "Error3=bootloader (aka SPL or hboot)" >> $logfile
    echo "success=false" >> $logfile
    exit
fi
return
}

removecmtd ()
{
dumpimg
KCMDline=""
flashimg
for MTDPart in system cache userdata;do
    SizeMB=$(printf %d `awk '/'${MTDPart}'/ {print "0x"$2}' $mtdpart`|awk '{printf "%.3f", $1 / 1048576}')
    MTDPart=`echo $MTDPart|sed s/user//`
    echo|awk '{printf "%s%s%s%-9s%s%9.3f %s","Orig_","'$MTDPart'","Size=","'$MTDPart'","=",'$SizeMB',"MB\n"}' >> $logfile
done
echo "success=true" >> $logfile
exit
}
Optimum ()
{
# this function will look at the existing installation and write an mtdpartmap.txt based on used size
# mount everything
mount -a
for partition in system cache;do
    eval free=\$${partition}free
    eval ${partition}Opt=`df |awk '$NF == "/'${partition}'" {printf "%.3f", (($3 / 128) + '$free') / 0.125 }'`
    # (( used_kbytes / 128kb ) + Number_of_128k_blocks ) , covert to mb
done
sed s/systemMB=.*/systemMB=$systemOpt/ -i $config
sed s/cacheMB=.*/cacheMB=$cacheOpt/ -i $config
busybox unix2dos $config
# TODO
# backup existing ROM,
# patch recove*y's init.rc,
# erase_image ( kang one for RA ),
# do restore feature,
# stop recovery from Auto rebooting after scripted restore
# print what we did ( i.e. new sizes )

# and one day I will look at msm_nand ko  ^^ is cheap n easy
return
}

AutoPatch ()
{
# this function will compare users defined settings with current running recovery
# if they are different it will patch recovery
# if they match it will check the installed recovery's md5sum against the logged md5sum, and patch if they don't match
# if all those conditions are met, it will patch the boot.img with the running recovery's layout
# should have done this ages ago
readdmesg
readconfig
if [ "$boot" = "recovery" -o "$boot" = "boot" ];
then
    return
    # probably want to run test mode
fi
for MTDPart in system cache;do
    eval ${MTDPart}SizeMB=$(printf %d `awk '/'${MTDPart}'/ {print "0x"$2}' $mtdpart`|awk '{printf "%.3f", $1 / 1048576}')
done
if [ "$systemMB" != "$systemSizeMB" -o "$cacheMB" != "$cacheSizeMB" ];
then
    boot=recovery
    return
fi
spl=`awk -Fandroidboot.bootloader= '$0 = $2' /proc/cmdline|awk '$0 = $1'`
SpoofedSPL=`awk -Fandroidboot.bootloader= '$0 = $3' /proc/cmdline|awk '$0 = $1'`
if [ "$spl" != "$SPL" -a "$SpoofedSPL" != "$SPL" ];
then
    boot=recovery
else
    Recoverymd5=`md5sum /dev/mtd/$(awk -F: '/recovery/ {print $1}' $mtdpart)ro|awk '{print $1}'`
    if [ "$Recoverymd5" != "$recoverymd5" ];
    then
        boot=recovery
    else
        boot=boot
    fi
fi
return
}
#end functions
me=$0
boot=$1
opt=$2
wkdir=/tmp
sdcard=/sdcard
config=$sdcard/mtdpartmap.txt
mtdpart=/proc/mtd
dmesgmtdpart=/dev/mtdpartmap
logfile=$wkdir/cMTD.log
dmesg=dmesg
if [ "$#" = "3" ];
then
    # hack in a desktop test mode,
    # 1st opt is test, 2nd Anything, 3nd opt is dmesg sample
    # yeap, its crap, but will do for now
    wkdir=`pwd`
    sdcard=`pwd`
    config=$sdcard/mtdpartmap.txt
    mtdpart=`pwd`/mtd
    dmesgmtdpart=`pwd`/mtdpartmap
    logfile=$wkdir/cMTD.log
    dmesg="cat $3"
fi
if [ -e $logfile ];
then
    rm $logfile
fi
if [ "$boot" = "test" ];
then
    $dmesg > $sdcard/cMTD-testoutput.txt
    busybox sed s/serialno=.*\ a/serialno=XXXXXXXXXX\ a/g -i $sdcard/cMTD-testoutput.txt
    sh -x $me recovery testrun $3 >> $sdcard/cMTD-testoutput.txt 2>&1
    busybox unix2dos $sdcard/cMTD-testoutput.txt
    exit
fi

AutoPatch

echo "Mode=$boot" >> $logfile

if [ "$boot" = "remove" ];
then
    boot=recovery
    removecmtd
fi
if [ "$boot" = "recovery" ];
then
    checksizing
    CreateCMDline
elif [ "$boot" = "boot" ];
then
    GetCMDline
else
    echo "Error1=No Argument given" >> $logfile
    echo "Error2=script needs either:" >> $logfile
    echo "Error3=boot or recovery" >> $logfile
    echo "success=false" >> $logfile
    exit
fi
dumpimg
if [ "$opt" = "testrun" ];
then
    sed s/$boot/testrun/ -i $logfile 
    flashimg echo
else
    flashimg
fi
