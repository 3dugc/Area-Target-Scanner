// Minimal test: compile and run real xatlas on a small mesh
#include "ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

int main() {
    printf("Creating atlas...\n");
    xatlas::Atlas *atlas = xatlas::Create();

    // Simple 4-vertex, 2-face quad
    float verts[] = {
        0,0,0,  1,0,0,  1,1,0,  0,1,0
    };
    uint32_t indices[] = { 0,1,2, 0,2,3 };

    xatlas::MeshDecl decl;
    decl.vertexPositionData = verts;
    decl.vertexPositionStride = 12;
    decl.vertexCount = 4;
    decl.indexData = indices;
    decl.indexCount = 6;
    decl.indexFormat = xatlas::IndexFormat::UInt32;

    printf("AddMesh...\n");
    auto err = xatlas::AddMesh(atlas, decl);
    printf("AddMesh result: %d\n", (int)err);

    printf("ComputeCharts...\n");
    fflush(stdout);
    xatlas::ChartOptions co;
    co.maxCost = 16.0f;
    co.maxIterations = 4;
    xatlas::ComputeCharts(atlas, co);
    printf("Charts: %u\n", atlas->chartCount);

    printf("PackCharts...\n");
    fflush(stdout);
    xatlas::PackOptions po;
    po.resolution = 4096;
    po.padding = 2;
    xatlas::PackCharts(atlas, po);
    printf("Atlas: %ux%u\n", atlas->width, atlas->height);

    printf("Vertices: %u, Indices: %u\n",
        atlas->meshes[0].vertexCount, atlas->meshes[0].indexCount);

    xatlas::Destroy(atlas);
    printf("Done!\n");
    return 0;
}
