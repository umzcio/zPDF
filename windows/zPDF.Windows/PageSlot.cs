using System.ComponentModel;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace zPDF;

/// <summary>One page in the continuous view: its size at the current zoom, and its
/// image while it is on or near the screen.</summary>
public sealed class PageSlot(int index) : INotifyPropertyChanged
{
    private double _width, _height;
    private ImageSource? _image;

    public int Index { get; } = index;
    /// <summary>Receives this page's pointer input.</summary>
    public IPageHost? Host { get; init; }
    /// <summary>Page width in view points (the page's size at 100% is PointWidth × 96/72 DIPs).</summary>
    public double PointWidth { get; set; }
    /// <summary>Selection and search highlights, in view points.</summary>
    public IReadOnlyList<(Rect Rect, Mark Mark)> Marks { get; private set; } = [];
    public event Action? MarksChanged;

    public void SetMarks(IReadOnlyList<(Rect Rect, Mark Mark)> marks)
    {
        if (marks.Count == 0 && Marks.Count == 0) return;
        Marks = marks;
        MarksChanged?.Invoke();
    }

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
