using System.ComponentModel;
using Microsoft.UI.Xaml.Media;

namespace zPDF;

/// <summary>One page in the thumbnail sidebar; the image arrives after rendering.</summary>
public sealed class Thumbnail(int index, double width, double height) : INotifyPropertyChanged
{
    private ImageSource? _image;

    public int Index { get; } = index;
    public double Width { get; } = width;
    public double Height { get; } = height;
    public string Number => (Index + 1).ToString();
    public string Label => $"Page {Index + 1}";

    public ImageSource? Image
    {
        get => _image;
        set { _image = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image))); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
