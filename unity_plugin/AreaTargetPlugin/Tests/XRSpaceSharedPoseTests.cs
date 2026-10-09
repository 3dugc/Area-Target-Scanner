using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using AreaTargetPlugin.PointCloudLocalization;
namespace AreaTargetPlugin.Tests
{
    public class XRSpaceSharedPoseTests
    {
        [Test]
        public async Task SharedCorePose_IsDisplayedDirectly_WithoutSecondKalmanPass()
        {
            var go = new GameObject("shared-pose");
            try
            {
                var space = go.AddComponent<XRSpace>();
                space.AddProcessor(new KalmanDataProcessor());
                var pose = Matrix4x4.Translate(new Vector3(1, 2, 3));
                await space.SceneUpdate(new SceneUpdateData { Pose = pose });
                Assert.That(go.transform.position, Is.EqualTo(new Vector3(1, 2, 3)));
                await space.SceneUpdate(new SceneUpdateData { Pose = Matrix4x4.Translate(new Vector3(8, 9, 10)) });
                Assert.That(go.transform.position, Is.EqualTo(new Vector3(8, 9, 10)));
            }
            finally { Object.DestroyImmediate(go); }
        }
        [Test]
        public async Task InvalidCoreAlignment_HidesContentWithoutChangingPose()
        {
            var go = new GameObject("shared-pose");
            try
            {
                var space = go.AddComponent<XRSpace>();
                go.transform.position = new Vector3(1, 2, 3);
                await space.SceneUpdate(new SceneUpdateData { Ignore = true, SetVisibility = true, Visible = false });
                Assert.That(go.activeSelf, Is.False);
                Assert.That(go.transform.position, Is.EqualTo(new Vector3(1, 2, 3)));
            }
            finally { Object.DestroyImmediate(go); }
        }
    }
}
