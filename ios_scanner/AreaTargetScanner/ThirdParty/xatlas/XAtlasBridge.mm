#import "XAtlasBridge.h"
#include <cmath>

static NSString *const XAtlasBridgeErrorDomain = @"com.areatarget.xatlas";

@implementation XAtlasResult
@end

@implementation XAtlasBridge

+ (nullable XAtlasResult *)unwrapWithVertices:(const float *)vertices
                                  vertexCount:(int)vertexCount
                                      normals:(const float *)normals
                                        faces:(const uint32_t *)faces
                                    faceCount:(int)faceCount
                                        error:(NSError *_Nullable *_Nullable)error {
    // Validate inputs
    if (vertexCount <= 0 || faceCount <= 0 || !vertices || !faces) {
        if (error) {
            *error = [NSError errorWithDomain:XAtlasBridgeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid input: vertex or face data is empty"}];
        }
        return nil;
    }

    // Fast per-triangle UV layout: assign each triangle to a grid cell in the atlas.
    // Each triangle gets a unique non-overlapping UV region.
    // This is O(n) and completes in milliseconds.
    // For high-quality UV, run xatlas offline on the server side.

    // Grid: ceil(sqrt(faceCount)) cells per side
    int gridSize = (int)ceilf(sqrtf((float)faceCount));
    if (gridSize < 1) gridSize = 1;
    float cellSize = 1.0f / (float)gridSize;
    // Inset to avoid bleeding at cell boundaries
    float padding = cellSize * 0.02f;
    float innerSize = cellSize - 2.0f * padding;

    // Output: 3 vertices per face (no sharing — matches input topology)
    int outVertexCount = faceCount * 3;
    int outFaceCount = faceCount;

    NSMutableArray<NSNumber *> *outVertices = [NSMutableArray arrayWithCapacity:outVertexCount * 3];
    NSMutableArray<NSNumber *> *outNormals  = [NSMutableArray arrayWithCapacity:outVertexCount * 3];
    NSMutableArray<NSNumber *> *outUVs      = [NSMutableArray arrayWithCapacity:outVertexCount * 2];
    NSMutableArray<NSNumber *> *outFaces    = [NSMutableArray arrayWithCapacity:outFaceCount * 3];
    NSMutableArray<NSNumber *> *outOrigIdx  = [NSMutableArray arrayWithCapacity:outVertexCount];

    for (int fi = 0; fi < faceCount; fi++) {
        // Grid cell for this face
        int col = fi % gridSize;
        int row = fi / gridSize;
        float cellX = (float)col * cellSize + padding;
        float cellY = (float)row * cellSize + padding;

        // Triangle corners within the cell: (0,0), (1,0), (0,1)
        float uv[3][2] = {
            { cellX,              cellY },
            { cellX + innerSize,  cellY },
            { cellX,              cellY + innerSize }
        };

        uint32_t baseIdx = (uint32_t)(fi * 3);
        for (int j = 0; j < 3; j++) {
            uint32_t origIdx = faces[fi * 3 + j];

            // Position
            [outVertices addObject:@(vertices[origIdx * 3 + 0])];
            [outVertices addObject:@(vertices[origIdx * 3 + 1])];
            [outVertices addObject:@(vertices[origIdx * 3 + 2])];

            // Normal
            if (normals) {
                [outNormals addObject:@(normals[origIdx * 3 + 0])];
                [outNormals addObject:@(normals[origIdx * 3 + 1])];
                [outNormals addObject:@(normals[origIdx * 3 + 2])];
            } else {
                [outNormals addObject:@(0.0f)];
                [outNormals addObject:@(1.0f)];
                [outNormals addObject:@(0.0f)];
            }

            // UV (already normalized to [0,1])
            [outUVs addObject:@(uv[j][0])];
            [outUVs addObject:@(uv[j][1])];

            // Original vertex index
            [outOrigIdx addObject:@(origIdx)];
        }

        // Face indices: sequential
        [outFaces addObject:@(baseIdx + 0)];
        [outFaces addObject:@(baseIdx + 1)];
        [outFaces addObject:@(baseIdx + 2)];
    }

    // Build result
    XAtlasResult *result = [[XAtlasResult alloc] init];
    result.vertices = [outVertices copy];
    result.normals = [outNormals copy];
    result.uvCoordinates = [outUVs copy];
    result.faces = [outFaces copy];
    result.originalVertexIndices = [outOrigIdx copy];
    result.vertexCount = outVertexCount;
    result.faceCount = outFaceCount;

    return result;
}

@end
