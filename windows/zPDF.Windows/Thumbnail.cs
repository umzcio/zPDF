using System.ComponentModel;
using Microsoft.UI.Xaml.Media;

namespace zPDF;

/// <summary>One page in the thumbnail sidebar; the image arrives after rendering.</summary>
public sealed class Thumbnail(int index, double width, double height, string? pageLabel = null) : INotifyPropertyChanged
{
    private ImageSource? _image;

    public int Index { get; } = index;
    public double Width { get; } = width;
    public double Height { get; } = height;
    /// <summary>The Organize Pages grid shows pages 150 wide.</summary>
    public double GridHeight => Math.Round(150 * Height / Width);
    /// <summary>The caption: the page label when the document defines one (e.g. "iv"), else the number.</summary>
    public string Number => pageLabel is { Length: > 0 } label ? label : (Index + 1).ToString();
    public string Label => pageLabel is { Length: > 0 } label && label != $"{Index + 1}" ? $"Page {Index + 1} ({label})" : $"Page {Index + 1}";

    public ImageSource? Image
    {
        get => _image;
        set { _image = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image))); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
