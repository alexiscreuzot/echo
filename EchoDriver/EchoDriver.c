#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/syslog.h>

#ifndef kAudioClockAlgorithmSimpleIIR
#define kAudioClockAlgorithmSimpleIIR 'siir'
#endif

#define kPlugIn_BundleID        "com.alexiscreuzot.echo.driver"
#define kDevice_Name            "Echo"
#define kDevice_Manufacturer    "Alexis Creuzot"
#define kDevice_UID             "EchoDevice_UID"
#define kDevice_ModelUID        "EchoDevice_ModelUID"

#define kChannelCount           2
#define kSampleRate             48000.0
#define kRingBufferFrames       16384
#define kBytesPerFrame          (kChannelCount * (UInt32)sizeof(Float32))

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4
};

#define FailWithAction(cond, act, handler, msg) do { if (cond) { { act; } goto handler; } } while (0)
#define RequireSize(needed) do { if (inDataSize < (needed)) { return kAudioHardwareBadPropertySizeError; } } while (0)

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;

static UInt64 gIOIsRunning = 0;
static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gNumberTimeStamps = 0;
static UInt64 gAnchorHostTime = 0;
static Float64 gPreviousTicks = 0.0;
static bool gInputStreamActive = true;
static bool gOutputStreamActive = true;

static Float32 gRingBuffer[kRingBufferFrames * kChannelCount];
static Float64 gLastOutputSampleTime = 0.0;
static Boolean gRingIsClear = true;

static const AudioStreamBasicDescription kFormat = {
    .mSampleRate       = kSampleRate,
    .mFormatID         = kAudioFormatLinearPCM,
    .mFormatFlags      = kAudioFormatFlagsNativeFloatPacked,
    .mBytesPerPacket   = kBytesPerFrame,
    .mFramesPerPacket  = 1,
    .mBytesPerFrame    = kBytesPerFrame,
    .mChannelsPerFrame = kChannelCount,
    .mBitsPerChannel   = 32,
    .mReserved         = 0
};

void *Echo_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT Echo_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Echo_AddRef(void *inDriver);
static ULONG Echo_Release(void *inDriver);
static OSStatus Echo_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Echo_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Echo_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Echo_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Echo_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Echo_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Echo_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean Echo_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus Echo_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus Echo_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Echo_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Echo_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus Echo_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Echo_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Echo_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Echo_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Echo_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Echo_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Echo_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static Boolean HasPlugInProperty(const AudioObjectPropertyAddress *inAddress);
static Boolean HasDeviceProperty(const AudioObjectPropertyAddress *inAddress);
static Boolean HasStreamProperty(const AudioObjectPropertyAddress *inAddress);
static OSStatus GetPlugInPropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus GetDevicePropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 *outDataSize);
static OSStatus GetStreamPropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 *outDataSize);
static OSStatus GetPlugInPropertyData(const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Echo_QueryInterface,
    Echo_AddRef,
    Echo_Release,
    Echo_Initialize,
    Echo_CreateDevice,
    Echo_DestroyDevice,
    Echo_AddDeviceClient,
    Echo_RemoveDeviceClient,
    Echo_PerformDeviceConfigurationChange,
    Echo_AbortDeviceConfigurationChange,
    Echo_HasProperty,
    Echo_IsPropertySettable,
    Echo_GetPropertyDataSize,
    Echo_GetPropertyData,
    Echo_SetPropertyData,
    Echo_StartIO,
    Echo_StopIO,
    Echo_GetZeroTimeStamp,
    Echo_WillDoIOOperation,
    Echo_BeginIOOperation,
    Echo_DoIOOperation,
    Echo_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static void RetainReturnedString(CFStringRef *slot, CFStringRef value) {
    *slot = value;
    CFRetain(*slot);
}

static void CopyStereoLayout(AudioChannelLayout *layout) {
    memset(layout, 0, offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription)));
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = 2;
    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
}

__attribute__((visibility("default")))
void *Echo_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
#pragma unused(inAllocator)
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

static HRESULT Echo_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    HRESULT answer = 0;
    CFUUIDRef requested = NULL;

    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(outInterface == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    FailWithAction(requested == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
    } else {
        answer = E_NOINTERFACE;
    }
    CFRelease(requested);

Done:
    return answer;
}

static ULONG Echo_AddRef(void *inDriver) {
#pragma unused(inDriver)
    pthread_mutex_lock(&gStateMutex);
    ++gRefCount;
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value;
}

static ULONG Echo_Release(void *inDriver) {
#pragma unused(inDriver)
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) {
        --gRefCount;
    }
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value;
}

static OSStatus Echo_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );

    gHost = inHost;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 nanosPerTick = ((Float64)timebase.numer) / ((Float64)timebase.denom);
    gHostTicksPerFrame = (1.0e9 / nanosPerTick) / kSampleRate;
    memset(gRingBuffer, 0, sizeof(gRingBuffer));

Done:
    return answer;
}

static OSStatus Echo_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
#pragma unused(inDriver, inDescription, inClientInfo, outDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Echo_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
#pragma unused(inDriver, inDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Echo_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
#pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus Echo_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
#pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus Echo_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
#pragma unused(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo)
    return 0;
}

static OSStatus Echo_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
#pragma unused(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo)
    return 0;
}

static Boolean Echo_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
#pragma unused(inClientProcessID)
    if (inDriver != gDriverRef || inAddress == NULL) {
        return false;
    }
    switch (inObjectID) {
        case kObjectID_PlugIn:        return HasPlugInProperty(inAddress);
        case kObjectID_Device:        return HasDeviceProperty(inAddress);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return HasStreamProperty(inAddress);
        default:                      return false;
    }
}

static Boolean HasPlugInProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean HasDeviceProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            return true;
        default:
            return false;
    }
}

static Boolean HasStreamProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus Echo_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
#pragma unused(inClientProcessID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inAddress == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(outIsSettable == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(!Echo_HasProperty(inDriver, inObjectID, 0, inAddress), answer = kAudioHardwareUnknownPropertyError, Done, );

    *outIsSettable = false;
    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
            *outIsSettable = true;
        }
    }

Done:
    return answer;
}

static OSStatus Echo_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
#pragma unused(inClientProcessID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inAddress == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(outDataSize == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    switch (inObjectID) {
        case kObjectID_PlugIn:
            answer = GetPlugInPropertyDataSize(inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;
        case kObjectID_Device:
            answer = GetDevicePropertyDataSize(inAddress, outDataSize);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            answer = GetStreamPropertyDataSize(inAddress, outDataSize);
            break;
        default:
            answer = kAudioHardwareBadObjectError;
            break;
    }

Done:
    return answer;
}

static OSStatus GetPlugInPropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
#pragma unused(inQualifierDataSize, inQualifierData)
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 *outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 2 * sizeof(AudioObjectID);
            }
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return 0;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription));
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyDataSize(const AudioObjectPropertyAddress *inAddress, UInt32 *outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Echo_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
#pragma unused(inClientProcessID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inAddress == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(outDataSize == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(outData == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    switch (inObjectID) {
        case kObjectID_PlugIn:
            answer = GetPlugInPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Device:
            answer = GetDevicePropertyData(inAddress, inDataSize, outDataSize, outData);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            answer = GetStreamPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
            break;
        default:
            answer = kAudioHardwareBadObjectError;
            break;
    }

Done:
    return answer;
}

static OSStatus GetPlugInPropertyData(const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            RequireSize(sizeof(AudioObjectID));
            *((AudioObjectID *)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyManufacturer:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kDevice_Manufacturer));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            RequireSize(sizeof(AudioObjectID));
            ((AudioObjectID *)outData)[0] = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioPlugInPropertyBundleID:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kPlugIn_BundleID));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            RequireSize(sizeof(AudioObjectID));
            *((AudioObjectID *)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                CFStringRef uid = *((CFStringRef *)inQualifierData);
                if (uid != NULL && CFEqual(uid, CFSTR(kDevice_UID))) {
                    *((AudioObjectID *)outData) = kObjectID_Device;
                }
            }
            return 0;
        }
        case kAudioPlugInPropertyResourceBundle:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(""));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            RequireSize(sizeof(AudioObjectID));
            *((AudioObjectID *)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyName:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kDevice_Name));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyManufacturer:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kDevice_Manufacturer));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 count = 0;
            if (inAddress->mScope != kAudioObjectPropertyScopeOutput) {
                ids[count++] = kObjectID_Stream_Input;
            }
            if (inAddress->mScope != kAudioObjectPropertyScopeInput) {
                ids[count++] = kObjectID_Stream_Output;
            }
            RequireSize(count * sizeof(AudioObjectID));
            memcpy(outData, ids, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return 0;
        case kAudioDevicePropertyDeviceUID:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kDevice_UID));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioDevicePropertyModelUID:
            RequireSize(sizeof(CFStringRef));
            RetainReturnedString((CFStringRef *)outData, CFSTR(kDevice_ModelUID));
            *outDataSize = sizeof(CFStringRef);
            return 0;
        case kAudioDevicePropertyTransportType:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyRelatedDevices:
            RequireSize(sizeof(AudioObjectID));
            *((AudioObjectID *)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyClockDomain:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceIsAlive:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceIsRunning:
            RequireSize(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32 *)outData) = gIOIsRunning > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            RequireSize(sizeof(Float64));
            *((Float64 *)outData) = kSampleRate;
            *outDataSize = sizeof(Float64);
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            RequireSize(sizeof(AudioValueRange));
            ((AudioValueRange *)outData)->mMinimum = kSampleRate;
            ((AudioValueRange *)outData)->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            RequireSize(2 * sizeof(UInt32));
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription));
            RequireSize(size);
            CopyStereoLayout((AudioChannelLayout *)outData);
            *outDataSize = size;
            return 0;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = kRingBufferFrames;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyClockAlgorithm:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = kAudioClockAlgorithmSimpleIIR;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioDevicePropertyClockIsStable:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    const bool isInput = (inObjectID == kObjectID_Stream_Input);
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyClass:
            RequireSize(sizeof(AudioClassID));
            *((AudioClassID *)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            RequireSize(sizeof(AudioObjectID));
            *((AudioObjectID *)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        case kAudioStreamPropertyIsActive:
            RequireSize(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32 *)outData) = (isInput ? gInputStreamActive : gOutputStreamActive) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyDirection:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyTerminalType:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyStartingChannel:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyLatency:
            RequireSize(sizeof(UInt32));
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RequireSize(sizeof(AudioStreamBasicDescription));
            *((AudioStreamBasicDescription *)outData) = kFormat;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            RequireSize(sizeof(AudioStreamRangedDescription));
            AudioStreamRangedDescription *ranged = (AudioStreamRangedDescription *)outData;
            ranged->mFormat = kFormat;
            ranged->mSampleRateRange.mMinimum = kSampleRate;
            ranged->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return 0;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Echo_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inAddress == NULL, answer = kAudioHardwareIllegalOperationError, Done, );
    FailWithAction(inData == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    if ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) &&
        inAddress->mSelector == kAudioStreamPropertyIsActive) {
        FailWithAction(inDataSize < sizeof(UInt32), answer = kAudioHardwareBadPropertySizeError, Done, );
        pthread_mutex_lock(&gStateMutex);
        bool *flag = (inObjectID == kObjectID_Stream_Input) ? &gInputStreamActive : &gOutputStreamActive;
        *flag = (*((const UInt32 *)inData) != 0);
        pthread_mutex_unlock(&gStateMutex);
    } else {
        answer = kAudioHardwareUnknownPropertyError;
    }

Done:
    return answer;
}

static OSStatus Echo_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
#pragma unused(inClientID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inDeviceObjectID != kObjectID_Device, answer = kAudioHardwareBadObjectError, Done, );

    pthread_mutex_lock(&gStateMutex);
    if (gIOIsRunning == UINT64_MAX) {
        answer = kAudioHardwareIllegalOperationError;
    } else {
        if (gIOIsRunning == 0) {
            pthread_mutex_lock(&gIOMutex);
            memset(gRingBuffer, 0, sizeof(gRingBuffer));
            gRingIsClear = true;
            gLastOutputSampleTime = 0.0;
            gNumberTimeStamps = 0;
            gPreviousTicks = 0.0;
            gAnchorHostTime = mach_absolute_time();
            pthread_mutex_unlock(&gIOMutex);
        }
        ++gIOIsRunning;
    }
    pthread_mutex_unlock(&gStateMutex);

Done:
    return answer;
}

static OSStatus Echo_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
#pragma unused(inClientID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inDeviceObjectID != kObjectID_Device, answer = kAudioHardwareBadObjectError, Done, );

    pthread_mutex_lock(&gStateMutex);
    if (gIOIsRunning == 0) {
        answer = kAudioHardwareIllegalOperationError;
    } else {
        --gIOIsRunning;
    }
    pthread_mutex_unlock(&gStateMutex);

Done:
    return answer;
}

static OSStatus Echo_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
#pragma unused(inClientID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inDeviceObjectID != kObjectID_Device, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(outSampleTime == NULL || outHostTime == NULL || outSeed == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    pthread_mutex_lock(&gIOMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRingBuffer = gHostTicksPerFrame * ((Float64)kRingBufferFrames);
    Float64 nextTickOffset = gPreviousTicks + hostTicksPerRingBuffer;
    UInt64 nextHostTime = gAnchorHostTime + ((UInt64)nextTickOffset);
    if (nextHostTime <= currentHostTime) {
        ++gNumberTimeStamps;
        gPreviousTicks = nextTickOffset;
    }
    *outSampleTime = gNumberTimeStamps * kRingBufferFrames;
    *outHostTime = gAnchorHostTime + ((UInt64)gPreviousTicks);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);

Done:
    return answer;
}

static OSStatus Echo_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
#pragma unused(inClientID)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inDeviceObjectID != kObjectID_Device, answer = kAudioHardwareBadObjectError, Done, );

    Boolean willDo = false;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
        default:
            break;
    }
    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }

Done:
    return answer;
}

static OSStatus Echo_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return 0;
}

static OSStatus Echo_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
#pragma unused(inClientID, ioSecondaryBuffer)
    OSStatus answer = 0;
    FailWithAction(inDriver != gDriverRef, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inDeviceObjectID != kObjectID_Device, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inStreamObjectID != kObjectID_Stream_Input && inStreamObjectID != kObjectID_Stream_Output, answer = kAudioHardwareBadObjectError, Done, );
    FailWithAction(inIOCycleInfo == NULL || ioMainBuffer == NULL, answer = kAudioHardwareIllegalOperationError, Done, );

    UInt64 sampleTime = (inOperationID == kAudioServerPlugInIOOperationReadInput)
        ? (UInt64)inIOCycleInfo->mInputTime.mSampleTime
        : (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
    UInt32 start = (UInt32)(sampleTime % kRingBufferFrames);
    UInt32 first = kRingBufferFrames - start;
    UInt32 second = 0;
    if (first >= inIOBufferFrameSize) {
        first = inIOBufferFrameSize;
    } else {
        second = inIOBufferFrameSize - first;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        Boolean underrun = gLastOutputSampleTime - (Float64)inIOBufferFrameSize < inIOCycleInfo->mInputTime.mSampleTime;
        if (underrun) {
            memset(ioMainBuffer, 0, inIOBufferFrameSize * kBytesPerFrame);
            if (!gRingIsClear) {
                memset(gRingBuffer, 0, sizeof(gRingBuffer));
                gRingIsClear = true;
            }
        } else {
            memcpy(ioMainBuffer, gRingBuffer + (start * kChannelCount), first * kBytesPerFrame);
            if (second > 0) {
                memcpy((Float32 *)ioMainBuffer + (first * kChannelCount), gRingBuffer, second * kBytesPerFrame);
            }
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        memcpy(gRingBuffer + (start * kChannelCount), ioMainBuffer, first * kBytesPerFrame);
        if (second > 0) {
            memcpy(gRingBuffer, (Float32 *)ioMainBuffer + (first * kChannelCount), second * kBytesPerFrame);
        }
        gLastOutputSampleTime = inIOCycleInfo->mOutputTime.mSampleTime + (Float64)inIOBufferFrameSize;
        gRingIsClear = false;
    }

Done:
    return answer;
}

static OSStatus Echo_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return 0;
}
