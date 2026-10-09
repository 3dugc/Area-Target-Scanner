using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    public class XRSpace : MonoBehaviour, ISceneUpdateable
    {
        public bool ProcessPoses { get; set; } = true;
        private List<IDataProcessor<SceneUpdateData>> _processors = new List<IDataProcessor<SceneUpdateData>>();

        public Transform GetTransform() => transform;

        public async Task SceneUpdate(SceneUpdateData data)
        {
            if (data.SetVisibility) gameObject.SetActive(data.Visible);
            if (data.Ignore) return;

            if (ProcessPoses)
            {
                foreach (var p in _processors)
                    data = await p.ProcessData(data, DataProcessorTrigger.NewData);
            }

            Vector3 position = new Vector3(data.Pose.m03, data.Pose.m13, data.Pose.m23);
            Quaternion rotation = data.Pose.rotation;
            transform.SetPositionAndRotation(position, rotation);
        }

        public async Task ResetScene()
        {
            foreach (var p in _processors)
                await p.ResetProcessor();
        }

        public void AddProcessor(IDataProcessor<SceneUpdateData> processor)
        {
            // Localization poses are already filtered by the shared native Session.
            // Keep this legacy registration source-compatible without filtering twice.
            if (processor is KalmanDataProcessor) return;
            _processors.Add(processor);
        }

        private async void OnDestroy()
        {
            foreach (var p in _processors)
                await p.ResetProcessor();
        }
    }
}
