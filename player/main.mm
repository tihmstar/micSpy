static int effect=12;
 
//#define kAudioUnitProperty_BusCount 11
 
//#define DELAY_UNIT
//#define REVERB_UNIT
 
#define kInputBus  1
#define kOutputBus  0
 
#import <AudioToolbox/AudioToolbox.h>
#define CHECK_BIT(var,pos) ((var) & (1<<(pos)))

#include <stdio.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <dirent.h>
#include <sys/stat.h>
#include <arpa/inet.h>
 
AudioUnit playUnit=NULL;
AudioUnit reverbUnit=NULL;
AudioUnit mixerUnit=NULL;
 
UInt32 frames=0;
 
void CheckError (OSStatus returnVal, const char *logTxt){
    if (returnVal){
        NSLog(@"error %u, %@",returnVal,[NSString stringWithUTF8String:logTxt]);
        exit(returnVal);
    }
}
 
 
static char* getCharCode(UInt32 code){
 
    char *selector = (char *)malloc(1 *sizeof(char ));
    //char selector[5];
    UInt32 selectorID = CFSwapInt32HostToBig (code);
    bcopy (&selectorID, selector, 4);
    selector[4] = '\0';
//    return [NSString stringWithCString:selector encoding:NSUTF8StringEncoding];
  return selector;
 
}
 
 
void dumpASBD(const AudioStreamBasicDescription *asbd)
{
    NSCParameterAssert(NULL != asbd);
 
    NSLog(@"AUVoiceIO mSampleRate         %f",  (double)asbd->mSampleRate);
//    NSLog(@"AUVoiceIO mFormatID           %.4s", (const char *)(&asbd->mFormatID));
    NSLog(@"AUVoiceIO mFormatID           %.4s", getCharCode(asbd->mFormatID));
    NSLog(@"AUVoiceIO mFormatFlags        %u",  (unsigned int)asbd->mFormatFlags);
    NSLog(@"AUVoiceIO mBytesPerPacket     %u",  (unsigned int)asbd->mBytesPerPacket);
    NSLog(@"AUVoiceIO mFramesPerPacket    %u",  (unsigned int)asbd->mFramesPerPacket);
    NSLog(@"AUVoiceIO mBytesPerFrame      %u",  (unsigned int)asbd->mBytesPerFrame);
    NSLog(@"AUVoiceIO mChannelsPerFrame   %u",  (unsigned int)asbd->mChannelsPerFrame);
    NSLog(@"AUVoiceIO mBitsPerChannel     %u",  (unsigned int)asbd->mBitsPerChannel);
    NSLog(@"AUVoiceIO mReserved           %u",  (unsigned int)asbd->mReserved);
}
 
void togglePlay();
 
 
int totalFrames=0;
static BOOL debugPrint=NO;
static BOOL equalizer=NO;

int gSocket = 0;
 
OSStatus RenderTone(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    uint32_t numChannel = 0;
    read(gSocket, &numChannel, sizeof(numChannel));
    
    uint32_t len = 0;
    read(gSocket, &len, sizeof(len));
    
    void *buf = malloc(len);
    assert(buf);
    
    size_t c = len;
    char *tmp = (char*) buf;
    while (c) {
        size_t r = read(gSocket, tmp, c);
        if (r == -1) {
            togglePlay();
            return -1;
        }
        
        c -= r;
        tmp += r;
    }
    
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = numChannel;
    ioData->mBuffers[0].mData = buf;
    ioData->mBuffers[0].mDataByteSize = len;
 
    totalFrames+=(int)inNumberFrames;
 
 
    return noErr;
}
 
 
extern "C" void configure(){
 
 
    // Configure the search parameters to find the default playback output unit
    // (called the kAudioUnitSubType_RemoteIO on iOS but
    // kAudioUnitSubType_DefaultOutput on Mac OS X)
 
    AudioComponentDescription defaultOutputDescription;
    defaultOutputDescription.componentType = kAudioUnitType_Output;
    defaultOutputDescription.componentSubType = 'rioc';
    defaultOutputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    defaultOutputDescription.componentFlags = 0;
    defaultOutputDescription.componentFlagsMask = 0;
 
    // Get the default playback output unit
    AudioComponent defaultOutput = AudioComponentFindNext(NULL, &defaultOutputDescription);
 
 
    // Create a new unit based on this that we'll use for output
    OSErr err = AudioComponentInstanceNew(defaultOutput, &playUnit);
    if (err){
        NSLog(@"GOT UNIT ERRO %d",(int)err);
    }
 
 
     //find all effect units available
 
    AudioComponentDescription acd = { 0 };
    acd.componentType = kAudioUnitType_Effect;
    //acd.componentSubType = kAudioUnitSubType_;
    AudioComponent comp = NULL;
    while((comp = AudioComponentFindNext(comp, &acd))) {
        AudioComponentDescription unitDescription = {0};
        AudioComponentGetDescription(comp, &unitDescription);
        NSLog(@"found unit with type %s subtype %s",getCharCode(kAudioUnitType_Effect),getCharCode(unitDescription.componentSubType));
        AudioUnit aUnit;
        AudioComponentInstanceNew(comp, &aUnit);
        NSString *name=NULL;
        UInt32 size = sizeof(name);
        AudioUnitGetProperty(aUnit, kAudioUnitProperty_NickName, 0, 0, &name, &size);
        if (name){
            NSLog(@"above unit has assigned name %@",name);
        }
 
    }
 
 
 
    //kAudioUnitScope_Global = 0
    //kAudioUnitScope_Input = 1
    //kAudioUnitScope_Output = 2
    // Bus == Element
    // Bus refers to a physical device, such as speaker, handset,internal microphone, etc
    // Elements (buses) are zero indexed. The Global scope always has exactly one element—element 0.
 
    UInt32 flag = 1;
    err = AudioUnitSetProperty(playUnit,
                                  kAudioOutputUnitProperty_EnableIO, // use io
                                  kAudioUnitScope_Output,  // we are referring to the output scope, that is, what the unit is broadcasting (and not receiving)
                                  0, // Element 0 is speaker output
                                  &flag, // set flag
                                  sizeof(flag));
    if (err){
        NSLog(@"ERROR FOR SETTING IO FOR INPUT %d",(int)err);
    }
 
 
    // Set our tone rendering function on the unit
    AURenderCallbackStruct input;
    input.inputProc = RenderTone;
    err = AudioUnitSetProperty(playUnit, kAudioUnitProperty_SetRenderCallback,  kAudioUnitScope_Global, 0, &input, sizeof(input));
 
    if (err){
         NSLog(@"ERROR EDO %d",(int)err);
     }
    // Set the format to 32 bit, single channel, floating point, linear PCM
 
    AudioStreamBasicDescription unitDesc;
    UInt32 unitDescSize=sizeof(unitDesc);
    err = AudioUnitGetProperty (playUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,0, &unitDesc, &unitDescSize);
    if (err){
        NSLog(@"error getting playinit stream format %d",(int)err);
    }
 
    AudioStreamBasicDescription fileDesc;
    UInt32 fileDescSize=sizeof(fileDesc);
 
    //err = AudioUnitSetProperty (playUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input ,0, &fileDesc, fileDescSize);
    err = 1;
    if (err){
 
        //unitDesc.mSampleRate = fileDesc.mSampleRate;
        
        unitDesc.mSampleRate         = 16000;
        unitDesc.mFormatID           = kAudioFormatLinearPCM;
        //audioFormat.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        unitDesc.mFormatFlags        = 12;
    //  audioFormat.mFormatFlags        = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        unitDesc.mBytesPerPacket     = 2;
        unitDesc.mFramesPerPacket    = 1;
        unitDesc.mBytesPerFrame      = 2;
        unitDesc.mChannelsPerFrame   = 1;
        unitDesc.mBitsPerChannel     = 16;
 
 
 
        err = AudioUnitSetProperty (playUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input ,0, &unitDesc, unitDescSize);
    }
 
    //if (debugPrint){
    //    printf("Unit format: AudioStreamBasicDescription:  %d ch,  %d Hz, '%s' (0x%08x) %d bits/channel, %d bytes/packet, %d frames/packet, %d bytes/frame\n",(int)unitDesc.mChannelsPerFrame,(int)unitDesc.mSampleRate,getCharCode(unitDesc.mFormatID),(unsigned int)unitDesc.mFormatFlags,(int)unitDesc.mBitsPerChannel,(int)unitDesc.mBytesPerPacket,(int)unitDesc.mFramesPerPacket,(int)unitDesc.mBytesPerFrame);
    //}
}
 
 
 
void togglePlay(void) {
 
    if (!playUnit)
    {
        // Create the audio unit as shown above
           configure();
 
        // Finalize parameters on the unit
        OSErr err = AudioUnitInitialize(playUnit);
        if (err){
            NSLog(@"INITIALIZE ERROR %d",(int)err);
        }
 
        // Start playback
        err = AudioOutputUnitStart(playUnit);
        if (err){
            NSLog(@"START ERROR %d",(int)err);
        }
 
        [[NSRunLoop currentRunLoop] run];
 
 
    }
    else
    {
    dispatch_async(dispatch_get_main_queue(),^{
        // Tear it down in reverse
        AudioOutputUnitStop(playUnit);
        AudioUnitUninitialize(playUnit);
        AudioComponentInstanceDispose(playUnit);
        playUnit = nil;
        exit(0);
 
    });
    }
}
 
 
 
 
 
int main(int argc, char **argv, char **envp) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        puts("[ERROR] socket");
        exit(-1);
    }
    
    int option = 1;
    
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &option, sizeof(option)) < 0) {
        puts("[ERROR] setsockopt");
        exit(-1);
    }
    
    struct sockaddr_in server;
    
    memset(&server, 0, sizeof (server));
    server.sin_family = AF_INET;
    server.sin_addr.s_addr = inet_addr("0.0.0.0");
    server.sin_port = htons(5005);
    
    if (bind(server_fd, (struct sockaddr*) &server, sizeof(server)) < 0) {
        puts("[ERROR] bind");
        exit(-1);
    }
    
    if (listen(server_fd, SOMAXCONN) < 0) {
        puts("[ERROR] listen");
        exit(-1);
    }
    
    gSocket = accept(server_fd, NULL, NULL);
 
 
    togglePlay();
    return 0;
}
