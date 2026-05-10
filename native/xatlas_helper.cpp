#include "xatlas.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr char kInputMagic[8] = {'X', 'A', 'T', 'L', 'A', 'S', 'I', 'N'};
constexpr char kOutputMagic[8] = {'X', 'A', 'T', 'L', 'A', 'S', 'O', 'U'};
constexpr uint32_t kProtocolVersion = 1;

std::mutex g_progress_mutex;

struct MeshInput {
    uint32_t vertex_count = 0;
    uint32_t face_count = 0;
    uint32_t atlas_size = 0;
    uint32_t max_iterations = 1;
    uint32_t flags = 0;
    std::vector<float> vertices;
    std::vector<float> normals;
    std::vector<uint32_t> faces;
};

bool read_exact(std::ifstream &stream, void *data, size_t bytes)
{
    stream.read(reinterpret_cast<char *>(data), static_cast<std::streamsize>(bytes));
    return stream.good();
}

bool write_exact(std::ofstream &stream, const void *data, size_t bytes)
{
    stream.write(reinterpret_cast<const char *>(data), static_cast<std::streamsize>(bytes));
    return stream.good();
}

bool read_u32(std::ifstream &stream, uint32_t &value)
{
    return read_exact(stream, &value, sizeof(value));
}

bool write_u32(std::ofstream &stream, uint32_t value)
{
    return write_exact(stream, &value, sizeof(value));
}

bool load_input(const std::string &path, MeshInput &input, std::string &error)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        error = "failed to open input file";
        return false;
    }

    char magic[8];
    uint32_t version = 0;
    if (!read_exact(stream, magic, sizeof(magic)) || std::memcmp(magic, kInputMagic, sizeof(magic)) != 0) {
        error = "invalid input magic";
        return false;
    }
    if (!read_u32(stream, version) || version != kProtocolVersion) {
        error = "unsupported input version";
        return false;
    }
    if (!read_u32(stream, input.vertex_count) ||
        !read_u32(stream, input.face_count) ||
        !read_u32(stream, input.atlas_size) ||
        !read_u32(stream, input.max_iterations) ||
        !read_u32(stream, input.flags)) {
        error = "invalid input header";
        return false;
    }
    if (input.vertex_count == 0 || input.face_count == 0) {
        error = "empty mesh";
        return false;
    }

    input.vertices.resize(static_cast<size_t>(input.vertex_count) * 3);
    input.normals.resize(static_cast<size_t>(input.vertex_count) * 3);
    input.faces.resize(static_cast<size_t>(input.face_count) * 3);

    if (!read_exact(stream, input.vertices.data(), input.vertices.size() * sizeof(float)) ||
        !read_exact(stream, input.normals.data(), input.normals.size() * sizeof(float)) ||
        !read_exact(stream, input.faces.data(), input.faces.size() * sizeof(uint32_t))) {
        error = "truncated input mesh";
        return false;
    }

    return true;
}

const char *category_name(xatlas::ProgressCategory category)
{
    if (category == xatlas::ProgressCategory::AddMesh)
        return "AddMesh";
    if (category == xatlas::ProgressCategory::ComputeCharts)
        return "ComputeCharts";
    if (category == xatlas::ProgressCategory::PackCharts)
        return "PackCharts";
    if (category == xatlas::ProgressCategory::BuildOutputMeshes)
        return "BuildOutputMeshes";
    return "Unknown";
}

bool progress_callback(xatlas::ProgressCategory category, int progress, void *)
{
    std::lock_guard<std::mutex> lock(g_progress_mutex);
    std::cout << "{\"type\":\"progress\",\"category\":\""
              << category_name(category)
              << "\",\"progress\":" << progress << "}" << std::endl;
    return true;
}

bool write_output(const std::string &path, const xatlas::Atlas *atlas, std::string &error)
{
    if (!atlas || atlas->meshCount == 0 || !atlas->meshes) {
        error = "xatlas produced no mesh";
        return false;
    }
    const xatlas::Mesh &mesh = atlas->meshes[0];
    if (mesh.vertexCount == 0 || mesh.indexCount == 0) {
        error = "xatlas produced empty mesh";
        return false;
    }

    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        error = "failed to open output file";
        return false;
    }

    if (!write_exact(stream, kOutputMagic, sizeof(kOutputMagic)) ||
        !write_u32(stream, kProtocolVersion) ||
        !write_u32(stream, mesh.vertexCount) ||
        !write_u32(stream, mesh.indexCount) ||
        !write_u32(stream, atlas->width) ||
        !write_u32(stream, atlas->height) ||
        !write_u32(stream, atlas->chartCount)) {
        error = "failed to write output header";
        return false;
    }

    std::vector<uint32_t> vmapping(mesh.vertexCount);
    std::vector<float> uvs(static_cast<size_t>(mesh.vertexCount) * 2);
    const float width = atlas->width > 0 ? static_cast<float>(atlas->width) : 1.0f;
    const float height = atlas->height > 0 ? static_cast<float>(atlas->height) : 1.0f;

    for (uint32_t i = 0; i < mesh.vertexCount; ++i) {
        const xatlas::Vertex &vertex = mesh.vertexArray[i];
        vmapping[i] = vertex.xref;
        uvs[static_cast<size_t>(i) * 2] = vertex.uv[0] / width;
        uvs[static_cast<size_t>(i) * 2 + 1] = vertex.uv[1] / height;
    }

    if (!write_exact(stream, vmapping.data(), vmapping.size() * sizeof(uint32_t)) ||
        !write_exact(stream, mesh.indexArray, static_cast<size_t>(mesh.indexCount) * sizeof(uint32_t)) ||
        !write_exact(stream, uvs.data(), uvs.size() * sizeof(float))) {
        error = "failed to write output mesh";
        return false;
    }

    return true;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc != 3) {
        std::cerr << "usage: xatlas_helper <input.bin> <output.bin>" << std::endl;
        return 2;
    }

    MeshInput input;
    std::string error;
    if (!load_input(argv[1], input, error)) {
        std::cerr << error << std::endl;
        return 3;
    }

    xatlas::Atlas *atlas = xatlas::Create();
    if (!atlas) {
        std::cerr << "failed to create atlas" << std::endl;
        return 4;
    }

    xatlas::SetProgressCallback(atlas, progress_callback, nullptr);

    xatlas::MeshDecl mesh_decl;
    mesh_decl.vertexCount = input.vertex_count;
    mesh_decl.vertexPositionData = input.vertices.data();
    mesh_decl.vertexPositionStride = sizeof(float) * 3;
    mesh_decl.vertexNormalData = input.normals.data();
    mesh_decl.vertexNormalStride = sizeof(float) * 3;
    mesh_decl.indexCount = input.face_count * 3;
    mesh_decl.indexData = input.faces.data();
    mesh_decl.indexFormat = xatlas::IndexFormat::UInt32;
    mesh_decl.faceCount = input.face_count;

    xatlas::AddMeshError add_error = xatlas::AddMesh(atlas, mesh_decl);
    if (add_error != xatlas::AddMeshError::Success) {
        std::cerr << "xatlas AddMesh failed: " << xatlas::StringForEnum(add_error) << std::endl;
        xatlas::Destroy(atlas);
        return 5;
    }
    xatlas::AddMeshJoin(atlas);

    xatlas::ChartOptions chart_options;
    chart_options.maxIterations = input.max_iterations;
    chart_options.normalDeviationWeight = 2.0f;
    chart_options.normalSeamWeight = 4.0f;

    xatlas::PackOptions pack_options;
    pack_options.resolution = input.atlas_size;
    pack_options.padding = 2;
    pack_options.bilinear = true;
    pack_options.bruteForce = (input.flags & 1u) != 0u;
    pack_options.blockAlign = (input.flags & 2u) != 0u;
    pack_options.createImage = true;

    xatlas::ComputeCharts(atlas, chart_options);
    xatlas::PackCharts(atlas, pack_options);

    if (!write_output(argv[2], atlas, error)) {
        std::cerr << error << std::endl;
        xatlas::Destroy(atlas);
        return 6;
    }

    std::cout << "{\"type\":\"done\",\"chart_count\":" << atlas->chartCount
              << ",\"width\":" << atlas->width
              << ",\"height\":" << atlas->height
              << "}" << std::endl;

    xatlas::Destroy(atlas);
    return 0;
}
