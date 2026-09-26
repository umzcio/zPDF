using System.ComponentModel;
using Microsoft.UI.Xaml.Media;

namespace zPDF;

/// <summary>One page in the continuous view: its size at the current zoom, and its
/// image while it is on or near the screen.</summary>
public sealed class PageSlot(int index) : INotifyPropertyChanged
{
    private double _width, _height;
    private ImageSource? _image;

    public int Index { get; } = index;
    public string Label => $"Page {Index + 1}";
    /// <summary>Zoom generation the current image was rendered for.</summary>
    public int RenderedFor { get; set; } = -1;

    public double Width { get => _width; set => Set(ref _width, value, nameof(Width)); }
    public double Height { get => _height; set => Set(ref _height, value, nameof(Height)); }
    public ImageSource? Image { get => _image; set => Set(ref _image, value, nameof(Image)); }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, string name)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
