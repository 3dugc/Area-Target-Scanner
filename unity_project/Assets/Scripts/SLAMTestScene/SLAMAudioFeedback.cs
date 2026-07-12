using UnityEngine;

/// <summary>
/// 管理跟踪状态转换时的音效播放。
/// 优先使用 Inspector 赋值的 AudioClip，
/// 未赋值时自动生成简单的 beep 音效。
/// </summary>
public class SLAMAudioFeedback : MonoBehaviour
{
    [SerializeField] private AudioSource audioSource;
    [SerializeField] private AudioClip trackingFoundClip;
    [SerializeField] private AudioClip trackingLostClip;

    void Awake()
    {
        if (audioSource == null)
        {
            audioSource = GetComponent<AudioSource>();
            if (audioSource == null)
                audioSource = gameObject.AddComponent<AudioSource>();
        }
        audioSource.playOnAwake = false;

        // 如果没有手动赋值，自动生成音效
        if (trackingFoundClip == null)
            trackingFoundClip = GenerateTone(523f, 0.15f, 1047f);

        if (trackingLostClip == null)
            trackingLostClip = GenerateTone(440f, 0.25f, 220f);
    }

    public void PlayTrackingFound()
    {
        if (audioSource != null && trackingFoundClip != null)
            audioSource.PlayOneShot(trackingFoundClip, 0.5f);
    }

    public void PlayTrackingLost()
    {
        if (audioSource != null && trackingLostClip != null)
            audioSource.PlayOneShot(trackingLostClip, 0.5f);
    }

    /// <summary>
    /// 运行时生成正弦波滑音音效，不需要外部文件。
    /// </summary>
    private static AudioClip GenerateTone(float startFreq, float duration, float endFreq)
    {
        int sampleRate = 44100;
        int sampleCount = Mathf.CeilToInt(sampleRate * duration);
        float[] samples = new float[sampleCount];
        float phase = 0f;

        for (int i = 0; i < sampleCount; i++)
        {
            float t = (float)i / sampleCount;
            float freq = Mathf.Lerp(startFreq, endFreq, t);
            float envelope = 1f;
            if (t < 0.05f) envelope = t / 0.05f;
            else if (t > 0.7f) envelope = (1f - t) / 0.3f;
            samples[i] = Mathf.Sin(phase * 2f * Mathf.PI) * envelope;
            phase += freq / sampleRate;
        }

        var clip = AudioClip.Create("GeneratedTone", sampleCount, 1, sampleRate, false);
        clip.SetData(samples, 0);
        return clip;
    }
}
