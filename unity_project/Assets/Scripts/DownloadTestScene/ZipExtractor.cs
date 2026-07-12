using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;

/// <summary>
/// 解压 ZIP 文件到指定目录，验证必需文件完整性。
/// 使用 System.IO.Compression.ZipFile 进行解压（.NET 标准库，无需额外依赖）。
/// </summary>
public class ZipExtractor
{
    private static readonly string[] RequiredFiles = { "optimized.glb", "features.db", "manifest.json" };

    public string LastError { get; private set; }

    /// <summary>
    /// 将 ZIP 解压到 outputDirectory，返回是否成功。
    /// 解压前清理目标目录（如已存在），防止旧文件残留。
    /// </summary>
    public bool Extract(string zipFilePath, string outputDirectory)
    {
        LastError = null;

        try
        {
            if (Directory.Exists(outputDirectory))
            {
                Directory.Delete(outputDirectory, true);
            }

            Directory.CreateDirectory(outputDirectory);
            ZipFile.ExtractToDirectory(zipFilePath, outputDirectory);
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return false;
        }
    }

    /// <summary>
    /// 验证目录中是否包含 optimized.glb, features.db, manifest.json。
    /// 返回 (是否全部存在, 缺失文件列表)。
    /// </summary>
    public (bool isValid, List<string> missingFiles) ValidateRequiredFiles(string directory)
    {
        var missingFiles = new List<string>();

        foreach (var file in RequiredFiles)
        {
            var filePath = Path.Combine(directory, file);
            if (!File.Exists(filePath))
            {
                missingFiles.Add(file);
            }
        }

        return (missingFiles.Count == 0, missingFiles);
    }
}
