#!/bin/sh

function checkForErrors()
{
  appName=$1
  instanceId=$2
  dumpFile=$3

  grep "Entity not found" ${appName}.${instanceId}.${dumpFile} >/dev/null
  if [ $? -ne 0 ]; then
    # Save each one with app and instance id so as to avoid another instance writing empty or error files into it.
    echo "###   Saved ${appName}.${instanceId}.${dumpFile} for instance: $instanceId of app: $appName"
  else
    echo "ERROR!! Resource $captureDumpUrl not found"
    echo "      on instance: $instanceId for app: $appName!"
    rm ${appName}.${instanceId}.${dumpFile}
  fi
}

# Check Number of arguments
if [ "$#" -lt 1 ]; then
  echo "Usage: captureDumps.sh  <appName> [path_of_file_or_directory>" 
  echo "    Requires 2 arguments... to retreive the thread or heap dumps created under /home/vcap/dumps"
  echo "    Name of the app deployed to CF " 
  echo "    Optional: sub-folder or files under the /home/vcap/dumps "

  exit -1
fi


appName=$1
filePath=$2

# Change the default as needed if CF API version changes 
CF_API_VERSION=v2

# Change DUMP_FOLDER location if need to pick from a different location than /home/vcap/dumps  
# Always the file path needs to be relative to /home/vcap
DUMP_FOLDER=dumps

APP_URL_PREFIX=/${CF_API_VERSION}/apps
DUMP_URL=/files/$DUMP_FOLDER/$filePath

tmpFile=`mktemp -t cfApp.${appName}.xxxx`

#echo TempFile is $tmpFile
CF_TRACE=true cf app $appName >& $tmpFile


appGuid=`grep summary $tmpFile | sed -e 's/summary.*//g;s/GET .*apps//g;s/\///g;' ` 

if [ "$appGuid" == "" ]; then
  echo "ERROR!  App $appName not found !!..."
  echo "Exiting...."
  echo ""
  exit -1
fi

# The running instances id comes with special characters to make them appear with color like: A
#`grep "running " $tmpFile | sed -e 's/ .*//g;s/^[^#]*#//g;s/\[.*//g;s///g' > /tmp/foo`
#
#^[[1;38m^[[0m  ^[[1;38mstate^[[0m  ^[[1;38msince^[[0m    ^[[1;38mcpu^[[0m  ^[[1;38mmemory^[[0m  ^[[1;38mdisk^[[0m······
#^[[1;36m#0^[[0m   running   2014-05-14 02:16:55 PM   0.5%   531.4M of 1G   0 of 1G···
#^[[1;36m#1^[[0m   running   2014-05-20 12:44:53 PM   1.0%   560.9M of 1G   0 of 1G···
# So the character  is a ctrl-[ character, not just a ^ followed by [, so removal of [ and ^ separately wont work

count=0
for instanceId in `grep "running " $tmpFile | sed -e 's/ .*//g;s/^[^#]*#//g;s/\[.*//g;s///g' `
do
  #echo "InstanceId is ${instanceId}"

  # Sample URL is /v2/apps/38699180-05c1-4c15-af24-f6c3fce5b1dc/instances/0/files/dumps/ to get listing of folders...
  # and then choose the folder
  # Sample URL is /v2/apps/38699180-05c1-4c15-af24-f6c3fce5b1dc/instances/0/files/dumps/05_20_14/threadDump.wls12c-0.104.22_01_11.txt
  # Sample URL is /v2/apps/38699180-05c1-4c15-af24-f6c3fce5b1dc/instances/1/files/dumps/05_20_14/threadDump.wls12c-0.104.22_01_11.txt
  captureDumpUrl="${APP_URL_PREFIX}/${appGuid}/instances/${instanceId}${DUMP_URL}"

  #echo Trying cf curl against $captureThreadDumpsUrl
  count=$((count+1))

  #echo url: $captureDumpUrl
  # If this is a heap dump, save it directly to local current directory
  #if [[ "$captureDumpUrl" == *hprof* ] -o [ "$captureDumpUrl" == "*.txt"]]; then

  dumpFile=`basename $captureDumpUrl`
  # Save txt or heap dumps as separate files
  # Dump to STDOUT for just file listing or other file types.
  case "$captureDumpUrl" in
      *hprof* )
      CF_TRACE=false cf curl $captureDumpUrl > $appName.$instanceId.$dumpFile
      checkForErrors $appName $instanceId $dumpFile
      ;;

      *txt   )
      CF_TRACE=false cf curl $captureDumpUrl > $appName.$instanceId.$dumpFile
      checkForErrors $appName $instanceId $dumpFile
      ;;

      * ) echo "Listing contents of file or directory for App: $appName , for instance: $instanceId"
          echo " (fetching from /home/vcap/$DUMP_FOLDER/${filePath} )"
          echo ""
          CF_TRACE=false cf curl $captureDumpUrl;;
  esac

  echo ""
done

rm $tmpFile

echo "Finished capture of directory/file contents for App: '$appName', with # of running instances: $count"
