from PIL import Image, ImageDraw, ImageFont

def create_grid_template():
    # Configuration
    width, height = 600, 400
    rows, cols = 2, 3
    rect_width = width // cols
    rect_height = height // rows
    
    # Create a new RGB image
    img = Image.new('RGB', (width, height), color='white')
    draw = ImageDraw.Draw(img)
    
    # Define colors and labels based on your image
    cells = [
        {"color": (255, 0, 0), "text": "1"},       # Red
        {"color": (0, 255, 0), "text": "2"},       # Green
        {"color": (0, 0, 255), "text": "3"},       # Blue
        {"color": (255, 255, 0), "text": "4"},     # Yellow
        {"color": (255, 0, 255), "text": "5\nTop"},   # Magenta
        {"color": (0, 255, 255), "text": "6\nBottom"} # Cyan
    ]

    # Optional: Load a font (defaults to standard if not found)
    try:
        font = ImageFont.truetype("arial.ttf", 40)
    except:
        font = ImageFont.load_default()

    for i, cell in enumerate(cells):
        # Calculate grid position
        row = i // cols
        col = i % cols
        
        # Define coordinates
        x0 = col * rect_width
        y0 = row * rect_height
        x1 = x0 + rect_width
        y1 = y0 + rect_height
        
        # Draw the rectangle
        draw.rectangle([x0, y0, x1, y1], fill=cell["color"], outline="black")
        
        # Calculate text position (center of the rectangle)
        text_bbox = draw.multiline_textbbox((0, 0), cell["text"], font=font)
        text_w = text_bbox[2] - text_bbox[0]
        text_h = text_bbox[3] - text_bbox[1]
        
        tx = x0 + (rect_width - text_w) / 2
        ty = y0 + (rect_height - text_h) / 2
        
        # Draw text (white for better contrast)
        draw.multiline_text((tx, ty), cell["text"], fill="white", font=font, align="center")

    # Save and show
    img.save('template_output.png')
    img.show()

if __name__ == "__main__":
    create_grid_template()