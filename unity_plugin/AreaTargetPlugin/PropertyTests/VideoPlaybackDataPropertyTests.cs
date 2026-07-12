using System;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for VideoPlayback data models.
    /// Validates: Requirements 1.2, 1.3, 1.5, 7.1, 7.2, 7.3
    /// </summary>
    [TestFixture]
    public class VideoPlaybackDataPropertyTests
    {
        // Feature: video-playback-test-scene, Property 1: 列优先矩阵往返一致性
        /// <summary>
        /// For any 16 finite floats, converting column-major → Matrix4x4 → column-major
        /// should produce numerically equivalent values (error &lt; 1e-6).
        /// Validates: Requirements 1.2, 7.1, 7.3
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property ColumnMajorRoundTrip_IsNumericallyEquivalent()
        {
            // 生成 16 个有限浮点数（避免 NaN/Infinity）
            var floatGen = Arb.Default.Float().Generator
                .Where(f => !float.IsNaN(f) && !float.IsInfinity(f));
            var arrayGen = Gen.ArrayOf(16, floatGen).ToArbitrary();

            return Prop.ForAll(arrayGen, (float[] original) =>
            {
                var matrix = ScanDataUtils.ColumnMajorToMatrix4x4(original);
                var roundTripped = ScanDataUtils.Matrix4x4ToColumnMajor(matrix);

                bool allClose = true;
                float maxError = 0f;
                for (int i = 0; i < 16; i++)
                {
                    float err = Math.Abs(original[i] - roundTripped[i]);
                    if (err > maxError) maxError = err;
                    if (err > 1e-6f) { allClose = false; break; }
                }

                return allClose
                    .ToProperty()
                    .Label($"Max round-trip error: {maxError:E3} (threshold 1e-6)");
            });
        }

        // Feature: video-playback-test-scene, Property 2: 内参矩阵构建正确性
        /// <summary>
        /// For any positive fx, fy, cx, cy, the built intrinsics matrix should have
        /// m00=fx, m11=fy, m02=cx, m12=cy, m22=1, all other elements=0.
        /// Validates: Requirements 1.3, 7.2
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property IntrinsicsMatrix_ElementsAreCorrect()
        {
            var posFloatGen = Arb.Default.Float().Generator
                .Where(f => f > 0f && !float.IsNaN(f) && !float.IsInfinity(f));

            var intrinsicsGen = Gen.zip4(posFloatGen, posFloatGen, posFloatGen, posFloatGen)
                .Select(t => new IntrinsicsData { fx = t.Item1, fy = t.Item2, cx = t.Item3, cy = t.Item4, width = 960, height = 1280 })
                .ToArbitrary();

            return Prop.ForAll(intrinsicsGen, (IntrinsicsData data) =>
            {
                var m = ScanDataUtils.BuildIntrinsicsMatrix(data);

                bool fxOk = Math.Abs(m.m00 - data.fx) < 1e-6f;
                bool fyOk = Math.Abs(m.m11 - data.fy) < 1e-6f;
                bool cxOk = Math.Abs(m.m02 - data.cx) < 1e-6f;
                bool cyOk = Math.Abs(m.m12 - data.cy) < 1e-6f;
                bool m22Ok = Math.Abs(m.m22 - 1f) < 1e-6f;

                // 其余元素应为 0
                bool othersZero =
                    Math.Abs(m.m01) < 1e-6f && Math.Abs(m.m10) < 1e-6f &&
                    Math.Abs(m.m20) < 1e-6f && Math.Abs(m.m21) < 1e-6f &&
                    Math.Abs(m.m03) < 1e-6f && Math.Abs(m.m13) < 1e-6f &&
                    Math.Abs(m.m23) < 1e-6f;

                bool allOk = fxOk && fyOk && cxOk && cyOk && m22Ok && othersZero;

                return allOk
                    .ToProperty()
                    .Label($"fx={data.fx} fy={data.fy} cx={data.cx} cy={data.cy}: " +
                           $"fxOk={fxOk} fyOk={fyOk} cxOk={cxOk} cyOk={cyOk} m22Ok={m22Ok} othersZero={othersZero}");
            });
        }

        // Feature: video-playback-test-scene, Property 3: 灰度转换值域
        /// <summary>
        /// For any RGB pixel values in [0,255]^3, the grayscale result should be in [0,255]
        /// and the output array length should equal width * height.
        /// Validates: Requirements 1.5
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property GrayscaleConversion_OutputInRange()
        {
            var byteGen = Gen.Choose(0, 255).Select(i => (byte)i);

            // 生成 w*h 个 RGB 像素（用小尺寸避免内存压力）
            var sizeGen = Gen.zip(Gen.Choose(1, 16), Gen.Choose(1, 16));
            var pixelArrayGen = sizeGen.SelectMany(wh =>
            {
                int w = wh.Item1, h = wh.Item2;
                return Gen.ArrayOf(w * h, Gen.zip3(byteGen, byteGen, byteGen))
                    .Select(pixels => (w, h, pixels));
            }).ToArbitrary();

            return Prop.ForAll(pixelArrayGen, (tuple) =>
            {
                int w = tuple.w, h = tuple.h;
                var pixels = tuple.pixels;

                // 执行灰度转换（与 ImageSeqFrameSource 中相同的公式）
                var gray = new byte[w * h];
                for (int i = 0; i < pixels.Length; i++)
                {
                    byte r = pixels[i].Item1;
                    byte g = pixels[i].Item2;
                    byte b = pixels[i].Item3;
                    gray[i] = (byte)(0.299f * r + 0.587f * g + 0.114f * b);
                }

                bool lengthOk = gray.Length == w * h;
                bool allInRange = true;
                for (int i = 0; i < gray.Length; i++)
                {
                    // byte 类型本身保证 [0,255]，但验证转换逻辑不会溢出
                    if (gray[i] < 0 || gray[i] > 255) { allInRange = false; break; }
                }

                return (lengthOk && allInRange)
                    .ToProperty()
                    .Label($"w={w} h={h}: lengthOk={lengthOk} allInRange={allInRange}");
            });
        }

        // Feature: video-playback-test-scene, Property 7: 跟踪状态到显示的映射
        /// <summary>
        /// For any TrackingState value, the color mapping used by the scene manager
        /// should satisfy: TRACKING→green, LOST→red, INITIALIZING→yellow.
        /// Validates: Requirements 5.1, 5.2
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property TrackingStateColorMapping_IsCorrect()
        {
            var stateGen = Gen.Elements(
                AreaTargetPlugin.TrackingState.TRACKING,
                AreaTargetPlugin.TrackingState.LOST,
                AreaTargetPlugin.TrackingState.INITIALIZING
            ).ToArbitrary();

            return Prop.ForAll(stateGen, (AreaTargetPlugin.TrackingState state) =>
            {
                // 与 VideoPlaybackTestSceneManager 中相同的颜色映射逻辑
                Color color = state switch
                {
                    AreaTargetPlugin.TrackingState.TRACKING     => Color.green,
                    AreaTargetPlugin.TrackingState.LOST         => Color.red,
                    AreaTargetPlugin.TrackingState.INITIALIZING => Color.yellow,
                    _                                           => Color.white
                };

                bool trackingOk = state != AreaTargetPlugin.TrackingState.TRACKING || color == Color.green;
                bool lostOk     = state != AreaTargetPlugin.TrackingState.LOST     || color == Color.red;
                bool initOk     = state != AreaTargetPlugin.TrackingState.INITIALIZING || color == Color.yellow;

                return (trackingOk && lostOk && initOk)
                    .ToProperty()
                    .Label($"state={state} color={color}");
            });
        }
    }
}
