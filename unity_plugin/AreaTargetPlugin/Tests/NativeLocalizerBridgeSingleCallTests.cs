using System;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    // Run with Unity Test Framework's serial runner: this fixture temporarily
    // changes process-wide trace environment and static capability state.
    // Unity's custom NUnit does not expose NonParallelizableAttribute.
    public class NativeLocalizerBridgeSingleCallTests
    {
        [Test]
        public void ProcessFrame_FirstProbeAndCachedOutVersion_ProcessEachFrameOnce()
        {
            const string traceVariable = "VL_DIAGNOSTIC_TRACE";
            string previousTrace = Environment.GetEnvironmentVariable(traceVariable);
            string tracePath = Path.Combine(Path.GetTempPath(), "area-target-single-call-" + Guid.NewGuid() + ".jsonl");
            FieldInfo checkedField = typeof(NativeLocalizerBridge).GetField("_checkedOutVersion", BindingFlags.NonPublic | BindingFlags.Static);
            FieldInfo hasField = typeof(NativeLocalizerBridge).GetField("_hasOutVersion", BindingFlags.NonPublic | BindingFlags.Static);
            bool previousChecked = (bool)checkedField.GetValue(null);
            bool previousHas = (bool)hasField.GetValue(null);
            IntPtr handle = IntPtr.Zero;
            try
            {
                Environment.SetEnvironmentVariable(traceVariable, tracePath);
                checkedField.SetValue(null, false);
                hasField.SetValue(null, false);
                handle = NativeLocalizerBridge.vl_create();
                Assert.AreNotEqual(IntPtr.Zero, handle);
                Assert.AreEqual(1, NativeLocalizerBridge.vl_build_index(handle));
                var image = new byte[64 * 64];

                var first = NativeLocalizerBridge.ProcessFrameSafe(handle, image, 64, 64, 500, 500, 32, 32, 0, null);
                Assert.IsTrue(NativeLocalizerBridge.CheckedOutVersion);
                Assert.IsTrue(NativeLocalizerBridge.HasOutVersion);
                Assert.AreEqual(2, first.state);
                Assert.AreEqual(1, FrameEndCount(tracePath), "The capability probe must keep its result instead of processing the first frame twice.");

                var second = NativeLocalizerBridge.ProcessFrameSafe(handle, image, 64, 64, 500, 500, 32, 32, 0, null);
                Assert.AreEqual(2, second.state);
                Assert.AreEqual(2, FrameEndCount(tracePath), "A cached out-parameter entry point must process the next frame once.");
            }
            finally
            {
                if (handle != IntPtr.Zero) NativeLocalizerBridge.vl_destroy(handle);
                checkedField.SetValue(null, previousChecked);
                hasField.SetValue(null, previousHas);
                Environment.SetEnvironmentVariable(traceVariable, previousTrace);
                if (File.Exists(tracePath)) File.Delete(tracePath);
            }
        }

        private static int FrameEndCount(string path)
        {
            Assert.IsTrue(File.Exists(path), "The native diagnostic trace must exist; a missing trace cannot establish call counts.");
            return Regex.Matches(File.ReadAllText(path), "\"event\"\\s*:\\s*\"frame_end\"").Count;
        }
    }
}
