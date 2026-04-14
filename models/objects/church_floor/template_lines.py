from PIL import Image, ImageDraw

def create_transparent_grid():
    # Configuration
    width, height = 600, 400
    rows, cols = 2, 3
    
    # "RGBA" mode is required for transparency
    # (0, 0, 0, 0) -> R, G, B are 0, Alpha is 0 (Transparent)
    img = Image.new('RGBA', (width, height), color=(0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Calculate spacing
    row_step = height / rows
    col_step = width / cols
    
    # Line settings (R, G, B, A) -> Solid Black
    line_color = (0, 0, 0, 255) 
    line_width = 2

    # Draw horizontal lines
    for i in range(rows + 1):
        y = i * row_step
        if y >= height: y = height - 1
        draw.line([(0, y), (width, y)], fill=line_color, width=line_width)

    # Draw vertical lines
    for j in range(cols + 1):
        x = j * col_step
        if x >= width: x = width - 1
        draw.line([(x, 0), (x, height)], fill=line_color, width=line_width)

    # IMPORTANT: You must save as PNG to preserve transparency
    img.save('template_transparent.png', 'PNG')
    img.show()
    print("Transparent template saved as template_transparent.png")

if __name__ == "__main__":
    create_transparent_grid()