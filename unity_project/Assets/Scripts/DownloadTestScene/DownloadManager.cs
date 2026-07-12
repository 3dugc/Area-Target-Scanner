using System;
using System.Collections;
using UnityEngine;
using UnityEngine.Networking;

/// <summary>
/// 从指定 URL 下载文件到本地，提供进度回调。
/// 使用 UnityWebRequest + DownloadHandlerFile 直接写入磁盘，避免大文件占用内存。
/// </summary>
public class DownloadManager : IDisposable
{
    private readonly MonoBehaviour _host;
    private UnityWebRequest _request;
    private Coroutine _downloadCoroutine;
    private bool _disposed;

    public bool IsDownloading { get; private set; }
    public float Progress { get; private set; }
    public string LastError { get; private set; }

    public DownloadManager(MonoBehaviour host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
    }

    /// <summary>
    /// 启动异步下载。
    /// </summary>
    /// <param name="url">下载地址</param>
    /// <param name="destinationPath">本地保存路径</param>
    /// <param name="onProgress">进度回调 (0.0~1.0)</param>
    /// <param name="onComplete">完成回调，参数为本地文件路径</param>
    /// <param name="onError">错误回调，参数为错误描述</param>
    public Coroutine StartDownload(string url, string destinationPath,
                                   Action<float> onProgress,
                                   Action<string> onComplete,
                                   Action<string> onError)
    {
        if (IsDownloading)
        {
            onError?.Invoke("下载正在进行中");
            return null;
        }

        if (string.IsNullOrWhiteSpace(url))
        {
            LastError = "请输入有效的 URL";
            onError?.Invoke(LastError);
            return null;
        }

        _downloadCoroutine = _host.StartCoroutine(
            DownloadCoroutine(url, destinationPath, onProgress, onComplete, onError));
        return _downloadCoroutine;
    }

    private IEnumerator DownloadCoroutine(string url, string destinationPath,
                                          Action<float> onProgress,
                                          Action<string> onComplete,
                                          Action<string> onError)
    {
        IsDownloading = true;
        Progress = 0f;
        LastError = null;

        _request = UnityWebRequest.Get(url);
        _request.downloadHandler = new DownloadHandlerFile(destinationPath) { removeFileOnAbort = true };

        _request.SendWebRequest();

        while (!_request.isDone)
        {
            Progress = _request.downloadProgress;
            onProgress?.Invoke(Progress);
            yield return null;
        }

        // Final progress update
        Progress = _request.downloadProgress;
        onProgress?.Invoke(Progress);

        if (_request.result == UnityWebRequest.Result.ConnectionError)
        {
            LastError = _request.error;
            IsDownloading = false;
            onError?.Invoke(LastError);
        }
        else if (_request.result == UnityWebRequest.Result.ProtocolError)
        {
            LastError = $"HTTP {_request.responseCode}: {_request.error}";
            IsDownloading = false;
            onError?.Invoke(LastError);
        }
        else if (_request.result == UnityWebRequest.Result.DataProcessingError)
        {
            LastError = _request.error;
            IsDownloading = false;
            onError?.Invoke(LastError);
        }
        else
        {
            // Success
            Progress = 1f;
            IsDownloading = false;
            onComplete?.Invoke(destinationPath);
        }

        DisposeRequest();
    }

    /// <summary>
    /// 中止当前下载。
    /// </summary>
    public void Cancel()
    {
        if (!IsDownloading) return;

        if (_downloadCoroutine != null)
        {
            _host.StopCoroutine(_downloadCoroutine);
            _downloadCoroutine = null;
        }

        _request?.Abort();
        DisposeRequest();

        IsDownloading = false;
        LastError = "下载已取消";
    }

    private void DisposeRequest()
    {
        if (_request != null)
        {
            _request.Dispose();
            _request = null;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        Cancel();
        DisposeRequest();
    }
}
