#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
 
#import <dlfcn.h>
//#import <Speech/Speech.h>
 
 
#define kInputBusNumber 1
#define kOutputBusNumber 0
 
static BOOL printAudioLevel=NO;
static float sampleRate=16000;
 
extern void dumpASBD(const AudioStreamBasicDescription *asbd){
 
    NSCParameterAssert(NULL != asbd);
    
    NSLog(@"mSampleRate         %f",  (double)asbd->mSampleRate);
    NSLog(@"mFormatID           %.4s",(const char *)&asbd->mFormatID);
    NSLog(@"mFormatFlags        %u",  (unsigned int)asbd->mFormatFlags);
    NSLog(@"mBytesPerPacket     %u",  (unsigned int)asbd->mBytesPerPacket);
    NSLog(@"mFramesPerPacket    %u",  (unsigned int)asbd->mFramesPerPacket);
    NSLog(@"mBytesPerFrame      %u",  (unsigned int)asbd->mBytesPerFrame);
    NSLog(@"mChannelsPerFrame   %u",  (unsigned int)asbd->mChannelsPerFrame);
    NSLog(@"mBitsPerChannel     %u",  (unsigned int)asbd->mBitsPerChannel);
    NSLog(@"mReserved           %u",  (unsigned int)asbd->mReserved);
}
 
static ExtAudioFileRef recFile=nil;
static AudioUnit audioUnit=nil;
static AudioUnit *pointerUnit=nil;
static AudioStreamBasicDescription *fmt=NULL;
static NSString *fileURL=NULL;
 
/*static SFSpeechAudioBufferRecognitionRequest *request=NULL;
static SFSpeechRecognitionTask *task=NULL;
static AVAudioPCMBuffer *avbuffer=NULL;
static SFSpeechRecognizer * speechRecognizer=NULL;
 */
 
 
 
 
 
//AUDIO FREQUENCIES
 
//const UInt32 kMaxFrames = 512*3;
UInt32 kMaxFrames = 1024;
const Float32 kAdjust0DB = 1.5849e-13;
//const NSInteger kFrameInterval = 1; // Alter this to draw more or less often
static int minFrequency=85;
static int maxFrequency=1000;
static NSUInteger numOfBins=30;
static float lastSampleRate=0;
 
static FFTSetup fftSetup=NULL;
COMPLEX_SPLIT A;
int log2n, n, nOver2;
float  *dataBuffer=NULL;
 
size_t bufferCapacity, vindex;
int gain;
// buffers
float *heightsByFrequency, *speeds, *timesx, *tSqrts, *vts, *deltaHeights;
NSMutableArray *heightsByTime;
static int lastFFTNumberFrames=0;
 
static void freeBuffersIfNeeded() {
 
    if (heightsByFrequency) {
        free(heightsByFrequency);
    }
    if (speeds) {
        free(speeds);
    }
    if (timesx) {
        free(timesx);
    }
    if (tSqrts) {
        free(tSqrts);
    }
    if (vts) {
        free(vts);
    }
    if (deltaHeights) {
        free(deltaHeights);
    }
    
 
    
}
 
 
 
static void setNumOfBins(NSUInteger someNumOfBins) {
 
    numOfBins = MAX(1, someNumOfBins);
    // reset buffers
    freeBuffersIfNeeded();
 
    // create buffers
    heightsByFrequency = (float *)calloc(sizeof(float), numOfBins);
    speeds = (float *)calloc(sizeof(float), numOfBins);
    timesx = (float *)calloc(sizeof(float), numOfBins);
    tSqrts = (float *)calloc(sizeof(float), numOfBins);
    vts = (float *)calloc(sizeof(float), numOfBins);
    deltaHeights = (float *)calloc(sizeof(float), numOfBins);
    heightsByTime = [NSMutableArray arrayWithCapacity:numOfBins];
    for (int i = 0; i < numOfBins; i++) {
        heightsByTime[i] = [NSNumber numberWithFloat:0];
    }
}
 
static void setupMyFFT(){
    
    // ftt setup
   // if (fftSetup){
 
   //   vDSP_destroy_fftsetup(fftSetup);
    //}
    lastFFTNumberFrames=0;
    gain=8;
    setNumOfBins(30);
    if (dataBuffer){
        free(dataBuffer);
    }
    if (A.realp){
        free(A.realp);
    }
    if (A.imagp){
        free(A.imagp);
    }
 
    dataBuffer = (float *)malloc(kMaxFrames * sizeof(float));
    log2n = log2f(kMaxFrames);
    n = 1 << log2n;
    nOver2 = kMaxFrames / 2;
    bufferCapacity = kMaxFrames;
    vindex = 0;
    A.realp = (float *)malloc(nOver2 * sizeof(float));
    A.imagp = (float *)malloc(nOver2 * sizeof(float));
    fftSetup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
     
    // inherited properties
 
}
 
 
static void processFrequencies(float * data, int inNumberFrames, float sampleRate){
    
 
    if (!fftSetup){
        setupMyFFT();
        NSLog(@"NO FFT!");
        return;
    }
    /*if (lastFFTNumberFrames && (lastFFTNumberFrames!=inNumberFrames)){
        
        NSLog(@"crash Making FFT BECAUSE FRAMES CHANGED! last %d in %d",lastFFTNumberFrames, inNumberFrames);
        
        setupMyFFT(inNumberFrames);
 
        return;
    }*/
    
    lastFFTNumberFrames=inNumberFrames;
 
    int read = (int)(bufferCapacity - vindex);
 
    if (read > inNumberFrames) {
     
        memcpy((float *)dataBuffer + vindex, data, inNumberFrames * sizeof(float));
        vindex += inNumberFrames;
        NSLog(@"read > inNumerFrames %u rate %f",inNumberFrames,sampleRate);
    } 
    else {
 
        // if we enter this conditional, our buffer will be filled and we should
        // perform the FFT.
        NSLog(@"processing fft...");
        
        memcpy((float *)dataBuffer + vindex, data, read * sizeof(float));
 
        // reset the vindex.
        vindex = 0;
 
        // fft
     
        vDSP_ctoz((COMPLEX *)dataBuffer, 2, &A, 1, nOver2);
        if (!fftSetup ){
            setupMyFFT();
            //NSLog(@"crash Making FFT INSIDE FUNCTION!");
            return;
        }
        vDSP_fft_zrip(fftSetup, &A, 1, log2n, FFT_FORWARD);
        vDSP_ztoc(&A, 1, (COMPLEX *)dataBuffer, 2, nOver2);
 
        // convert to dB
    
        Float32 one = 1, zero = 0;
        vDSP_vsq(dataBuffer, 1, dataBuffer, 1, inNumberFrames);
        vDSP_vsadd(dataBuffer, 1, &kAdjust0DB, dataBuffer, 1, inNumberFrames);
        vDSP_vdbcon(dataBuffer, 1, &one, dataBuffer, 1, inNumberFrames, 0);
        vDSP_vthr(dataBuffer, 1, &zero, dataBuffer, 1, inNumberFrames);
 
        // aux
        float mul = (sampleRate / bufferCapacity) / 2;
        int minFrequencyIndex = minFrequency / mul;
        int maxFrequencyIndex = maxFrequency / mul;
        int numDataPointsPerColumn = (maxFrequencyIndex - minFrequencyIndex) / numOfBins;
        float maxHeight = 0;
 
        for (NSUInteger i = 0; i < numOfBins; i++) {
            // calculate new column height
            float avg = 0;
            vDSP_meanv(dataBuffer + minFrequencyIndex + i * numDataPointsPerColumn, 1, &avg, numDataPointsPerColumn);
            float columnHeight = avg * gain; //MAX(avg * gain, 250); //480: height of line
            
            maxHeight = MAX(maxHeight, columnHeight);
 
            // set column height, speed and time if needed
            if (columnHeight > heightsByFrequency[i]) {
                heightsByFrequency[i] = columnHeight;
                speeds[i] = 0;
                timesx[i] = 0;
            }
            else{
               heightsByFrequency[i] = columnHeight;
            }
 
        }
 
        NSMutableArray *array=[NSMutableArray array];
        for (int i=0; i<numOfBins; i++){
            [array addObject:[NSNumber numberWithFloat:heightsByFrequency[i]]];
        }
    
        NSDictionary *dict=[NSDictionary dictionaryWithObjectsAndKeys:array,@"heights",NULL];
        //[ipcCenter sendMessageName:@"frequencies" userInfo:dict];
        NSLog(@"frequencies: %@",dict);
 
        [heightsByTime addObject:[NSNumber numberWithFloat:maxHeight]];
        if (heightsByTime.count > numOfBins) {
            [heightsByTime removeObjectAtIndex:0];
        }
 
 
 
    }
 
 
}
// END OF AUDIO FREQUENCIES
 
 
static OSStatus recordingCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData){

AudioUnit *unit = (AudioUnit*)inRefCon;

    OSStatus err;
 
    AudioStreamBasicDescription desc;
        desc.mSampleRate        = sampleRate;
         desc.mFormatID            = kAudioFormatLinearPCM;
        desc.mFormatFlags        = 12;
        desc.mBytesPerPacket    = 2;
        desc.mFramesPerPacket    = 1;
        desc.mBytesPerFrame        = 2;
        desc.mChannelsPerFrame    = 1;
        desc.mBitsPerChannel    = 16;
 
    if (recFile==nil){
        //dumpASBD(&desc);
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)fileURL, kCFURLPOSIXPathStyle, false);
        err=ExtAudioFileCreateWithURL(url, kAudioFileCAFType, &desc, NULL, kAudioFileFlags_EraseFile, &recFile);
        err=ExtAudioFileSetProperty(recFile, kExtAudioFileProperty_ClientDataFormat, sizeof(desc), &desc);
    
    }
    
    AudioBuffer buffer;
    buffer.mDataByteSize = inNumberFrames * desc.mBytesPerFrame;
    buffer.mNumberChannels = desc.mChannelsPerFrame;
    buffer.mData = malloc(buffer.mDataByteSize);
 
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0] = buffer;
 
    err=AudioUnitRender(*pointerUnit,ioActionFlags,inTimeStamp,inBusNumber,inNumberFrames,&bufferList);
    //NSLog(@"RENDER status %d busNumber %d inNumberFrames %d",(int)err,(int)inBusNumber,(int)inNumberFrames);
    
    // RECOGNIZE SPEECH
    
 /*
    if (buffer.mDataByteSize){
        
         
     
        AVAudioFormat *chFormat = [[AVAudioFormat alloc] initWithStreamDescription:&desc];
 
        AVAudioPCMBuffer *thePCMBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:chFormat frameCapacity:inNumberFrames];  
 
        thePCMBuffer.frameLength = thePCMBuffer.frameCapacity;  
 
 
        memset(thePCMBuffer.int16ChannelData[0], 0, thePCMBuffer.frameLength * chFormat.streamDescription->mBytesPerFrame);  
 
        AudioStreamBasicDescription *asbd=(AudioStreamBasicDescription*)chFormat.streamDescription;
        UInt32 bsize=bufferList.mBuffers[0].mDataByteSize;
     
        memcpy(thePCMBuffer.int16ChannelData[0],bufferList.mBuffers[0].mData,thePCMBuffer.frameLength * chFormat.streamDescription->mBytesPerFrame);
         
        [request appendAudioPCMBuffer:thePCMBuffer];
 
 
         [chFormat release];
        [thePCMBuffer release];
    
 
     
        
    }
     */
     
     
 
    // ANALYZE AUDIO
    SInt16 *analyzebuffer=(SInt16 *)bufferList.mBuffers[0].mData;
    SInt16 Amax=0;
    for (int i=0;i<inNumberFrames;i++){
        SInt16 value=analyzebuffer[i];
        if (value>Amax){
            Amax=value;
        }
    }
    int numberOfBlocks=Amax/(32767/80); //set 80 as max
    
    char blocks[numberOfBlocks];
 
    for (int i=0; i<numberOfBlocks; i++){
 
        blocks[i]='#';
    }
    blocks[numberOfBlocks]='\0';
    if (printAudioLevel){
        printf("%s",blocks);
        printf("\n\033[F\033[J");
    }
    
 
    // END ANALYSIS 
    
    err=ExtAudioFileWrite(recFile,inNumberFrames,&bufferList);
 
    /*if(!task){
        
        task=[speechRecognizer recognitionTaskWithRequest:request resultHandler: ^(SFSpeechRecognitionResult* result, NSError *error){
        
            if(result) {
                dispatch_async(dispatch_get_main_queue(),^{
                    printf("Recognized: %s\n",[result.bestTranscription.formattedString UTF8String]);
                });
 
            } 
            else if (error){
                dispatch_async(dispatch_get_main_queue(),^{
                    printf("error: %s\n",[[error description] UTF8String]);
                });
            }
        
        }];
    
    }*/
    
    return noErr;
}
 
void printUsage(){
    printf("Usage: record [PATH_TO_NEW_FILE].caf [-e] [-s sampleRate]\n");
    printf("\n");
}
 
int main(int argc, char **argv, char **envp) {
 
    NSMutableArray *arguments=[[[NSProcessInfo processInfo] arguments] mutableCopy];
    [arguments removeObjectAtIndex:0];
    if ([arguments count]<1 || [arguments count]>4){
 
        printUsage();   
        exit(0);
    }
    
    printAudioLevel=YES;
    fileURL=[arguments firstObject];
    [arguments removeObjectAtIndex:0];
    
    for (int i=0; i<[arguments count]; i++){
     
        NSString *argument = [arguments objectAtIndex:i];
        [arguments removeObjectAtIndex:i];
        if ([argument isEqual:@"-e"]){
            printAudioLevel=NO;
            i--;
            continue;
        }
        if ([argument isEqual:@"-s"] ){
            if (i<[arguments count]){
                NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
                f.numberStyle = NSNumberFormatterDecimalStyle;
                NSNumber *myNumber = [f numberFromString:[arguments objectAtIndex:i]];               
                const char *value=[[arguments objectAtIndex:i] UTF8String];
                for (int x=0; x<strlen(value); x++){
                    if (!isdigit(value[x])){
                        printUsage();
                        exit(1);
                    }
                }
                sampleRate=[myNumber floatValue];
                i--;
                continue;
            }
        }
        i--;
         
    }
 
 
    
    
    /*if (![[fileURL pathExtension] isEqual:@"caf"]){
        printf("File must have a .caf extension \n");
        printf("\n");
        exit(0);
    
    }*/
 
#if TARGET_OS_IPHONE
//  [[objc_getClass("AVAudioSession") sharedInstance] setCategory:@"AVAudioSessionCategoryPlayAndRecord" error:NULL];
//  [[objc_getClass("AVAudioSession") sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:NULL];
//  [[objc_getClass("AVAudioSession") sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
#endif  
    
    OSStatus status;
    // Describe audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
    desc.componentSubType = kAudioUnitSubType_HALOutput;
#endif
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
 
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    status = AudioComponentInstanceNew(inputComponent, &audioUnit);
    
    if (status){
        printf("error finding audio unit \n");
        return 1;
    }
    pointerUnit=&audioUnit;
    
    // Enable IO for recording
    
    UInt32 flag = 1;
    status = AudioUnitSetProperty(audioUnit, 
                                  kAudioOutputUnitProperty_EnableIO, 
                                  kAudioUnitScope_Input, 
                                  kInputBusNumber,
                                  &flag, 
                                  sizeof(flag));
    if (status){
        printf("error setting audiounit enable I/O\n");
        return 1;
    }
    
    // Disable playback IO
    flag = 0;
    status = AudioUnitSetProperty(audioUnit, 
                                  kAudioOutputUnitProperty_EnableIO, 
                                  kAudioUnitScope_Output, 
                                  kOutputBusNumber,
                                  &flag, 
                                  sizeof(flag));

 
    
    AudioStreamBasicDescription audioFormat;
    //audioFormat.mSampleRate           = 16000.00;
    audioFormat.mSampleRate         = sampleRate;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    //audioFormat.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFormatFlags        = 12;
//  audioFormat.mFormatFlags        = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mBytesPerPacket     = 2;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mBytesPerFrame      = 2;
    audioFormat.mChannelsPerFrame   = 1;
    audioFormat.mBitsPerChannel     = 16;
 
 
    
    // Describe format
    /*AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate         = 16000;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags        = kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger; //41;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mChannelsPerFrame   = 1;
    audioFormat.mBitsPerChannel     = 16;
    audioFormat.mBytesPerPacket     = 2;
    audioFormat.mBytesPerFrame      = 2;
    */
    
    /*
    format->mSampleRate = 44000.0;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFramesPerPacket = 1;
    format->mChannelsPerFrame = 2;
    format->mBytesPerFrame = format->mBytesPerPacket = format->mChannelsPerFrame * sizeof(SInt16);
    format->mBitsPerChannel = 16;
    format->mReserved = 0;
    format->mFormatFlags = ~kAudioFormatFlagIsBigEndian | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh;
    */
    
    /*AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate         = 44100;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags        = kAudioFormatFlagIsBigEndian | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh;//kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mChannelsPerFrame   = 1;
    audioFormat.mBitsPerChannel     = 16;
    audioFormat.mBytesPerPacket     = 2;
    audioFormat.mBytesPerFrame      = 2;
    
    
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate         = 44100;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags        = kLinearPCMFormatFlagIsSignedInteger;//kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mChannelsPerFrame   = 1;
    audioFormat.mBitsPerChannel     = 16;
    //audioFormat.mBytesPerPacket   = 2;
    audioFormat.mBytesPerFrame      = audioFormat.mBytesPerPacket = audioFormat.mChannelsPerFrame * sizeof(SInt16);
    */
    fmt=&audioFormat;
 
    // Apply format
    
    status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &audioFormat, sizeof(audioFormat));
    if (status){
        printf("error setting audiounit output stream format\n");
        return 1;
    }
 
    // Set input callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = &recordingCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)&audioUnit;
    status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, sizeof(callbackStruct));
    if (status){
        printf("error setting input callback\n");
        return 1;
    }
  
    status = AudioUnitInitialize(audioUnit);
    if (status){
        printf("ERROR INITIALIZING IO UNIT %d\n",(int)status);
        return 1;
    }
     
        
    /*
    request=[[objc_getClass("SFSpeechURLRecognitionRequest") alloc] initWithURL: [NSURL fileURLWithPath:fileURL]];
    
    //request=[[SFSpeechAudioBufferRecognitionRequest alloc] init];
    
    //SFSpeechURLRecognitionRequest *request = [[SFSpeechURLRecognitionRequest alloc] initWithURL:[NSURL fileURLWithPath:@"/tmp/test.caf"]];
    
    speechRecognizer=[[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    task=[speechRecognizer recognitionTaskWithRequest:request resultHandler: ^(SFSpeechRecognitionResult* result, NSError *error){
        
            if(result) {
                dispatch_async(dispatch_get_main_queue(),^{
                    printf("Recognized: %s\n",[result.bestTranscription.formattedString UTF8String]);
                });
 
            } 
            else if (error){
                dispatch_async(dispatch_get_main_queue(),^{
                    printf("error: %s\n",[[error description] UTF8String]);
                });
            }
        
        }];
        
    [[NSRunLoop currentRunLoop] run];
    return 0;
    
    
    */
    
    printf("getting output unit stream format...\n");
        AudioStreamBasicDescription streamDescription;
        UInt32 descSize = sizeof(streamDescription);
        OSStatus err=AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output ,1, &streamDescription, &descSize);
        printf("get stream format error status : %d\n",(int)err);
        dumpASBD((const AudioStreamBasicDescription *)&streamDescription);
     
    status = AudioOutputUnitStart(audioUnit);
    if (status){
        printf("error starting audio unit, status %d\n",(int)status);
        return 1;
    } 
 
    printf("Recording... Press enter to exit.\n");
    while (1){
        char ch=getchar();
        if (ch){
            AudioOutputUnitStop(audioUnit);
            AudioUnitUninitialize(audioUnit);
            AudioComponentInstanceDispose(audioUnit);   
            ExtAudioFileDispose(recFile);
            recFile=nil;
            printf("Done. Check %s\n",[fileURL UTF8String]);
            exit(0);
        }
    }
     
    AudioOutputUnitStop(audioUnit);
    AudioUnitUninitialize(audioUnit);
    AudioComponentInstanceDispose(audioUnit);   
    ExtAudioFileDispose(recFile);
    recFile=nil;
 
    return 0;
} 
