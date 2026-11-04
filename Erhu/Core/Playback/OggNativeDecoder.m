#import "OggNativeDecoder.h"
#import <AVFoundation/AVFoundation.h>
#include <stdlib.h>
#include <string.h>
#import <ogg/ogg.h>
#import <opus/opusfile.h>
#import <vorbis/vorbisfile.h>

static BOOL Failed(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Erhu.OggDecoder" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSDictionary *Comments(char **comments, int *lengths, int count) {
    NSMutableDictionary *tags = [NSMutableDictionary new];
    NSUInteger bytes = 0;
    for (int i=0; i<count && i<10000; i++) {
        if (lengths[i] <= 0 || lengths[i] > 16*1024*1024) continue;
        bytes += lengths[i]; if (bytes > 16*1024*1024) break;
        NSString *line = [[NSString alloc] initWithBytes:comments[i] length:lengths[i] encoding:NSUTF8StringEncoding];
        NSRange equals = [line rangeOfString:@"="];
        if (!line || equals.location == NSNotFound || equals.location == 0) continue;
        NSString *key = [[line substringToIndex:equals.location] uppercaseString];
        NSString *value = [line substringFromIndex:equals.location+1];
        if (!tags[key]) tags[key] = value;
        else if ([key isEqualToString:@"GENRE"]) tags[key] = [NSString stringWithFormat:@"%@; %@", tags[key], value];
    }
    return tags;
}
@implementation ERHUOggDecoder
+ (NSDictionary *)inspectURL:(NSURL *)url error:(NSError **)error {
    int code=0;
    OggOpusFile *opus = op_open_file(url.fileSystemRepresentation, &code);
    if (opus) {
        const OpusTags *tags=op_tags(opus,0);
        NSDictionary *comments=tags ? Comments(tags->user_comments,tags->comment_lengths,tags->comments) : @{};
        NSDictionary *info=@{@"codec":@"Opus", @"sampleRate":@48000, @"channels":@(op_channel_count(opus,0)), @"frames":@(op_pcm_total(opus,-1)), @"tags":comments};
        op_free(opus); return info;
    }
    OggVorbis_File vorbis;
    if (ov_fopen(url.fileSystemRepresentation,&vorbis) != 0) { Failed(error,@"This is not a readable Ogg Vorbis or Ogg Opus file."); return nil; }
    vorbis_info *format=ov_info(&vorbis,0);
    if (!format) { ov_clear(&vorbis); Failed(error,@"Could not read the Vorbis audio format."); return nil; }
    vorbis_comment *tags=ov_comment(&vorbis,0);
    NSDictionary *comments=tags ? Comments(tags->user_comments,tags->comment_lengths,tags->comments) : @{};
    NSDictionary *info=@{@"codec":@"Vorbis", @"sampleRate":@(format->rate), @"channels":@(format->channels), @"frames":@(ov_pcm_total(&vorbis,-1)), @"tags":comments};
    ov_clear(&vorbis); return info;
}
+ (BOOL)decodeURL:(NSURL *)url toURL:(NSURL *)destination isCancelled:(BOOL (^)(void))isCancelled error:(NSError **)error {
    NSDictionary *info=[self inspectURL:url error:error]; if (!info) return NO;
    int channels=[info[@"channels"] intValue]; double rate=[info[@"sampleRate"] doubleValue];
    if (channels<1 || channels>2 || rate<=0 || rate>384000) return Failed(error,@"Ogg playback currently supports mono and stereo recordings.");
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:channels interleaved:NO];
    if (!format) return Failed(error,@"The audio format is not supported by this iPhone.");
    AVAudioFile *output=[[AVAudioFile alloc] initForWriting:destination settings:format.settings commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
    if (!output) return NO;
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
    if (!buffer) return Failed(error,@"Could not allocate the audio decoder buffer.");
    int64_t written=0;
    if ([info[@"codec"] isEqualToString:@"Opus"]) {
        int code=0; OggOpusFile *input=op_open_file(url.fileSystemRepresentation,&code);
        if (!input) return Failed(error,@"Could not open the Opus recording.");
        float *interleaved=calloc(4096*channels,sizeof(float));
        if (!interleaved) { op_free(input); return Failed(error,@"Could not allocate the Opus buffer."); }
        BOOL ok=YES; int link=0;
        while (YES) {
            if (isCancelled()) { ok=Failed(error,@"Audio preparation cancelled."); break; }
            int frames=op_read_float(input,interleaved,4096*channels,&link);
            if (frames==0) break;
            if (frames<0 || op_channel_count(input,link)!=channels) { ok=Failed(error,@"The Opus stream is damaged or changes its channel layout."); break; }
            buffer.frameLength=frames;
            for (int c=0;c<channels;c++) for (int f=0;f<frames;f++) buffer.floatChannelData[c][f]=interleaved[f*channels+c];
            if (![output writeFromBuffer:buffer error:error]) { ok=NO; break; }
            written += frames;
        }
        free(interleaved); op_free(input); if (!ok) return NO;
    } else {
        OggVorbis_File input;
        if (ov_fopen(url.fileSystemRepresentation,&input)!=0) return Failed(error,@"Could not open the Vorbis recording.");
        BOOL ok=YES; int link=0;
        while (YES) {
            if (isCancelled()) { ok=Failed(error,@"Audio preparation cancelled."); break; }
            float **pcm=NULL; long frames=ov_read_float(&input,&pcm,4096,&link);
            if (frames==0) break;
            vorbis_info *current=ov_info(&input,link);
            if (frames<0 || !current || current->channels!=channels || current->rate!=(long)rate) { ok=Failed(error,@"The Vorbis stream is damaged or changes its audio format."); break; }
            buffer.frameLength=(AVAudioFrameCount)frames;
            for (int c=0;c<channels;c++) memcpy(buffer.floatChannelData[c],pcm[c],frames*sizeof(float));
            if (![output writeFromBuffer:buffer error:error]) { ok=NO; break; }
            written += frames;
        }
        ov_clear(&input); if (!ok) return NO;
    }
    output=nil;
    int64_t expected=[info[@"frames"] longLongValue];
    if (written<=0 || (expected>=0 && written!=expected)) return Failed(error,@"The Ogg recording did not decode completely.");
    return YES;
}
@end
