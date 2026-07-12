using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using AreaTargetPlugin;

namespace VideoPlaybackTestScene
{
    /// <summary>
    /// 从扫描数据目录加载图像序列帧源。
    /// 解析 poses.json（列优先 4x4 矩阵）和 intrinsics.json，
    /// 按需从磁盘读取 JPEG 并转换为灰度 CameraFrame。
    /// Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 7.1, 7.2
    /// </summary>
    public class ImageSeqFrameSource
    {
        /// <summary>帧总数</summary>
        public int FrameCount => _frames != null ? _frames.Count : 0;

        /// <summary>图像宽度（来自 intrinsics.json）</summary>
        public int ImageWidth { get; private set; }

        /// <summary>图像高度（来自 intrinsics.json）</summary>
        public int ImageHeight { get; private set; }

        /// <summary>加载错误信息，null 表示无错误</summary>
        public string LastError { get; private set; }

        private List<FrameEntry> _frames;
        private IntrinsicsData _intrinsics;
        private Matrix4x4 _intrinsicsMatrix;
        private string _scanDataPath;

        /// <summary>
        /// 加载扫描数据目录。解析 poses.json、intrinsics.json，枚举 images/ 下的帧列表。
        /// </summary>
        /// <param name="scanDataPath">扫描数据根目录路径</param>
        /// <returns>是否加载成功</returns>
        public bool Load(string scanDataPath)
        {
            LastError = null;
            _frames = null;
            _intrinsics = null;
            _scanDataPath = scanDataPath;

            // 检查目录是否存在
            if (!Directory.Exists(scanDataPath))
            {
                LastError = $"扫描数据目录不存在: {scanDataPath}";
                return false;
            }

            // 解析 intrinsics.json
            string intrinsicsPath = Path.Combine(scanDataPath, "intrinsics.json");
            if (!File.Exists(intrinsicsPath))
            {
                LastError = $"缺少内参文件: {intrinsicsPath}";
                return false;
            }

            try
            {
                string intrinsicsJson = File.ReadAllText(intrinsicsPath);
                _intrinsics = JsonUtility.FromJson<IntrinsicsData>(intrinsicsJson);
                if (_intrinsics == null)
                {
                    LastError = "intrinsics.json 解析失败：返回 null";
                    return false;
                }
            }
            catch (Exception ex)
            {
                LastError = $"intrinsics.json 解析错误: {ex.Message}";
                return false;
            }

            ImageWidth = _intrinsics.width;
            ImageHeight = _intrinsics.height;
            _intrinsicsMatrix = ScanDataUtils.BuildIntrinsicsMatrix(_intrinsics);

            // 解析 poses.json
            string posesPath = Path.Combine(scanDataPath, "poses.json");
            if (!File.Exists(posesPath))
            {
                LastError = $"缺少位姿文件: {posesPath}";
                return false;
            }

            try
            {
                string posesJson = File.ReadAllText(posesPath);
                // Unity JsonUtility 不支持科学计数法（如 1.23e-09），预处理替换
                posesJson = System.Text.RegularExpressions.Regex.Replace(
                    posesJson,
                    @"-?\d+\.?\d*[eE][+-]?\d+",
                    m => double.Parse(m.Value, System.Globalization.CultureInfo.InvariantCulture)
                              .ToString("F15", System.Globalization.CultureInfo.InvariantCulture)
                              .TrimEnd('0').TrimEnd('.'));
                var posesData = JsonUtility.FromJson<PosesData>(posesJson);
                if (posesData == null || posesData.frames == null)
                {
                    LastError = "poses.json 解析失败：frames 为 null";
                    return false;
                }

                // 按 index 排序
                posesData.frames.Sort((a, b) => a.index.CompareTo(b.index));
                _frames = posesData.frames;
            }
            catch (Exception ex)
            {
                LastError = $"poses.json 解析错误: {ex.Message}";
                return false;
            }

            if (_frames.Count == 0)
            {
                LastError = "poses.json 中没有帧数据";
                return false;
            }

            return true;
        }

        /// <summary>
        /// 获取指定帧索引的 CameraFrame（灰度图 + 内参矩阵）。
        /// 从磁盘读取 JPEG 并转灰度，图像文件缺失时返回全零灰度数据。
        /// </summary>
        /// <param name="frameIndex">帧索引 [0, FrameCount-1]</param>
        /// <returns>CameraFrame 结构体</returns>
        public CameraFrame GetFrame(int frameIndex)
        {
            if (_frames == null || frameIndex < 0 || frameIndex >= _frames.Count)
            {
                return new CameraFrame
                {
                    ImageData = new byte[ImageWidth * ImageHeight],
                    Width = ImageWidth,
                    Height = ImageHeight,
                    Intrinsics = _intrinsicsMatrix
                };
            }

            var entry = _frames[frameIndex];
            string imagePath = Path.Combine(_scanDataPath, entry.imageFile);

            if (!File.Exists(imagePath))
            {
                Debug.LogWarning($"[ImageSeqFrameSource] 图像文件缺失: {imagePath}");
                return new CameraFrame
                {
                    ImageData = new byte[ImageWidth * ImageHeight],
                    Width = ImageWidth,
                    Height = ImageHeight,
                    Intrinsics = _intrinsicsMatrix
                };
            }

            try
            {
                byte[] jpegBytes = File.ReadAllBytes(imagePath);
                var tex = new Texture2D(2, 2, TextureFormat.RGB24, false);
                ImageConversion.LoadImage(tex, jpegBytes);

                int w = tex.width;
                int h = tex.height;
                Color32[] pixels = tex.GetPixels32();
                byte[] gray = new byte[w * h];

                for (int i = 0; i < pixels.Length; i++)
                {
                    gray[i] = (byte)(0.299f * pixels[i].r + 0.587f * pixels[i].g + 0.114f * pixels[i].b);
                }

                UnityEngine.Object.Destroy(tex);

                return new CameraFrame
                {
                    ImageData = gray,
                    Width = w,
                    Height = h,
                    Intrinsics = _intrinsicsMatrix
                };
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[ImageSeqFrameSource] 读取图像失败 {imagePath}: {ex.Message}");
                return new CameraFrame
                {
                    ImageData = new byte[ImageWidth * ImageHeight],
                    Width = ImageWidth,
                    Height = ImageHeight,
                    Intrinsics = _intrinsicsMatrix
                };
            }
        }

        /// <summary>
        /// 获取指定帧的相机位姿（camera-to-world 4x4 矩阵）。
        /// </summary>
        /// <param name="frameIndex">帧索引 [0, FrameCount-1]</param>
        /// <returns>camera-to-world Matrix4x4，越界时返回单位矩阵</returns>
        public Matrix4x4 GetPose(int frameIndex)
        {
            if (_frames == null || frameIndex < 0 || frameIndex >= _frames.Count)
                return Matrix4x4.identity;

            var entry = _frames[frameIndex];
            if (entry.transform == null || entry.transform.Length != 16)
                return Matrix4x4.identity;

            return ScanDataUtils.ColumnMajorToMatrix4x4(entry.transform);
        }
    }
}
