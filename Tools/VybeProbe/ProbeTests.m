#import <XCTest/XCTest.h>
#import <MediaPipeTasksText/MediaPipeTasksText.h>
#import <math.h>

@interface ProbeTests : XCTestCase
@end
@implementation ProbeTests
- (void)testOfficialEmbeddingGemmaBundleOnIOS {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"embedding_gemma" ofType:@"task"];
    XCTAssertNotNil(path);
    MPPTextEmbedderOptions *options = [MPPTextEmbedderOptions new];
    options.baseOptions.modelAssetPath = path;
    options.l2Normalize = YES;
    NSError *error = nil;
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    MPPTextEmbedder *embedder = [[MPPTextEmbedder alloc] initWithOptions:options error:&error];
    double loadMs = (CFAbsoluteTimeGetCurrent() - began) * 1000;
    if (!embedder) {
        NSLog(@"VYBE_PROBE %@", @{ @"stage": @"load", @"error": error.localizedDescription ?: @"unknown" });
    }
    XCTAssertNotNil(embedder, @"Official .task could not load: %@", error);
    if (!embedder) return;
    NSArray<NSString *> *documents = @[
      @"genre: hip-hop; mood: dark atmospheric introspective rap; lyrics: alone in the city at night",
      @"genre: R&B soul; mood: romantic mellow warm; lyrics: stay with me my love",
      @"genre: electronic dance techno; tempo: 140 BPM; mood: energetic driving club music",
      @"genre: acoustic folk; mood: peaceful gentle reflective; instruments: acoustic guitar",
      @"genre: heavy metal; mood: aggressive intense; instruments: distorted guitars drums",
      @"genre: jazz; mood: relaxed; instruments: saxophone piano double bass"
    ];
    NSMutableArray<NSArray<NSNumber *> *> *vectors = [NSMutableArray new];
    for (NSString *text in documents) {
        MPPTextFormatContext *format = [MPPTextFormatContext new];
        format.embeddingType = MPPEmbeddingTypeRetrievalDocument;
        format.textRole = MPPTextRoleDocument;
        MPPTextEmbedderResult *result = [embedder embedText:text textFormatContext:format error:&error];
        NSArray<NSNumber *> *vector = result.embeddingResult.embeddings.firstObject.floatEmbedding;
        XCTAssertGreaterThan(vector.count, 0, @"Document inference: %@", error);
        if (!vector) return;
        [vectors addObject:vector];
    }
    NSArray<NSString *> *queries = @[@"dark late night rap", @"romantic mellow R&B", @"fast electronic club music", @"gentle acoustic folk", @"aggressive heavy metal", @"relaxed instrumental jazz"];
    NSUInteger correct = 0;
    for (NSUInteger q = 0; q < queries.count; q++) {
        MPPTextFormatContext *format = [MPPTextFormatContext new];
        format.embeddingType = MPPEmbeddingTypeRetrievalQuery;
        format.textRole = MPPTextRoleQuery;
        MPPTextEmbedderResult *result = [embedder embedText:queries[q] textFormatContext:format error:&error];
        NSArray<NSNumber *> *query = result.embeddingResult.embeddings.firstObject.floatEmbedding;
        XCTAssertEqual(query.count, vectors.firstObject.count);
        if (!query.count) return;
        double best = -INFINITY; NSUInteger winner = NSNotFound;
        for (NSUInteger d = 0; d < vectors.count; d++) {
            double dot = 0;
            for (NSUInteger i = 0; i < query.count; i++) dot += query[i].doubleValue * vectors[d][i].doubleValue;
            XCTAssertTrue(isfinite(dot));
            if (dot > best) { best = dot; winner = d; }
        }
        correct += winner == q;
    }
    NSLog(@"VYBE_PROBE %@", @{ @"stage": @"complete", @"dimensions": @(vectors.firstObject.count), @"modelLoadMs": @(loadMs), @"correctOfSix": @(correct), @"totalMs": @((CFAbsoluteTimeGetCurrent() - began) * 1000) });
    XCTAssertGreaterThanOrEqual(correct, 5, @"Basic synthetic relevance probe; not real-library quality validation");
}
@end
