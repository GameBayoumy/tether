using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

/// <summary>
/// Makes Play mode use the Tether OpenXR runtime, so a Unity project renders into the headset over Tether's Link.
///
/// Unity's OpenXR plug-in keeps its "Play Mode OpenXR Runtime" choice only in the editor's environment:
///   OTHER_XR_RUNTIME_JSON    - path used by the "Other" entry
///   XR_SELECTED_RUNTIME_JSON - path of the selected entry
/// and copies the selection into XR_RUNTIME_JSON (read by the OpenXR loader) when entering Play mode.
/// This script re-applies the Tether manifest after every domain reload.
///
/// Drop it into any Editor folder. Override the manifest path with Tether › Set Runtime Manifest… if Tether.app
/// isn't in /Applications.
/// </summary>
[InitializeOnLoad]
public static class TetherOpenXR
{
    const string PrefKey = "Tether.OpenXRRuntimeJson";
    const string DefaultRuntimeJson = "/Applications/Tether.app/Contents/Resources/openxr/tether_openxr.json";

    static string RuntimeJson => EditorPrefs.GetString(PrefKey, DefaultRuntimeJson);

    static TetherOpenXR()
    {
        Apply();
        EditorApplication.playModeStateChanged -= OnPlayModeChanged;
        EditorApplication.playModeStateChanged += OnPlayModeChanged;
    }

    [MenuItem("Tether/Use Tether For Play Mode")]
    static void Apply()
    {
        var path = RuntimeJson;
        AvoidUnreadableLoaderDirectories();
        Environment.SetEnvironmentVariable("OTHER_XR_RUNTIME_JSON", path);
        Environment.SetEnvironmentVariable("XR_SELECTED_RUNTIME_JSON", path);
        if (!File.Exists(path))
            Debug.LogWarning($"[Tether] OpenXR runtime manifest not found: {path}. Install Tether.app or use Tether › Set Runtime Manifest…");
    }

    [MenuItem("Tether/Set Runtime Manifest…")]
    static void ChooseManifest()
    {
        var path = EditorUtility.OpenFilePanel("Tether OpenXR runtime manifest", Path.GetDirectoryName(RuntimeJson), "json");
        if (string.IsNullOrEmpty(path))
            return;
        EditorPrefs.SetString(PrefKey, path);
        Apply();
    }

    static void OnPlayModeChanged(PlayModeStateChange state)
    {
        if (state != PlayModeStateChange.ExitingEditMode)
            return;
        AvoidUnreadableLoaderDirectories();
        Environment.SetEnvironmentVariable("XR_RUNTIME_JSON", RuntimeJson);
    }

    /// The Khronos loader searches $XDG_DATA_DIRS (default /usr/local/share:/usr/share) and fails with
    /// "Unknown failure" when one of them exists but can't be read, which happens on some Macs.
    static void AvoidUnreadableLoaderDirectories()
    {
        var current = Environment.GetEnvironmentVariable("XDG_DATA_DIRS");
        var dirs = string.IsNullOrEmpty(current) ? new[] { "/usr/local/share", "/usr/share" } : current.Split(':');
        var readable = dirs.Where(d =>
        {
            if (!Directory.Exists(d))
                return true;
            try { Directory.GetDirectories(d); return true; }
            catch { return false; }
        }).ToArray();
        if (readable.Length != dirs.Length)
            Environment.SetEnvironmentVariable("XDG_DATA_DIRS", readable.Length > 0 ? string.Join(":", readable) : "/usr/share");
    }
}
