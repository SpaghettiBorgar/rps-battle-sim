import std.stdio;
import etc.linux.memoryerror;
import bindbc.sdl;
import std.string;
import std.random;
import std.conv;
import std.math;

/// Exception for SDL related issues
class SDLException : Exception
{
	/// Creates an exception from SDL_GetError()
	this(string file = __FILE__, size_t line = __LINE__) nothrow @nogc
	{
		super(cast(string) SDL_GetError().fromStringz, file, line);
	}
}

enum RPS
{
	ROCK,
	PAPER,
	SCISSORS
}

struct Point
{
	real x;
	real y;

	real angleTo(Point p2)
	{
		return atan2(p2.x - this.x, p2.y - this.y);
	}

	real distance(Point p2)
	{
		import std.numeric : euclideanDistance;

		return euclideanDistance([this.x, this.y], [p2.x, p2.y]);
	}

	void movePolar(real angle, real distance)
	{
		this.x += cos(angle) * distance;
		this.y -= sin(angle) * distance;
	}

	auto opBinary(string op)(const Point rhs) const
	{
		mixin(q{return Point(x} ~ op ~ q{rhs.x, y} ~ op ~ q{rhs.y);});
	}

	auto opBinary(string op)(const real rhs) const
	{
		mixin(q{return Point(x} ~ op ~ q{rhs, y} ~ op ~ q{rhs);});
	}

	void opOpAssign(string op, T)(T rhs)
	{
		mixin(q{this = this} ~ op ~ q{rhs;});
	}

	string toString() const
	{
		return this.x.to!string ~ "," ~ this.y.to!string;
	}

	bool isDefined()
	{
		return !(isNaN(x) || isNaN(y));
	}
}

struct Particle
{
	RPS type;
	Point pos;
}

SDL_Renderer* sdlr;
bool running;
int windowW;
int windowH;
int mouseX;
int mouseY;
bool mouseL;
bool mouseM;
bool mouseR;
Uint8* keystates;
Uint16 keymods;
Particle[] particles;

void main()
{
	version(DMD)
	registerMemoryErrorHandler();

	writeln(sdlSupport);

	if (loadSDL() != sdlSupport)
		writeln("Error loading SDL library");

	if (SDL_Init(SDL_INIT_VIDEO) < 0)
		throw new SDLException();

	scope (exit)
		SDL_Quit();

	windowW = 600;
	windowH = 600;
	auto window = SDL_CreateWindow("SDL Application", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
		windowW, windowH, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
	if (!window)
		throw new SDLException();

	sdlr = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);

	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
	SDL_SetRenderDrawBlendMode(sdlr, SDL_BLENDMODE_BLEND);

	init();

	running = true;
	while (running)
	{
		pollEvents();
		tick();
		draw();
	}
}

void init()
{
	auto rnd = MinstdRand0();

	particles = [];
	foreach(i; 0..100)
	{
		particles ~= Particle(rnd.uniform!RPS, Point(uniform01() * windowW, uniform01() * windowH));
	}
}

void tick()
{
	import std.numeric : euclideanDistance;
	import std.math;
	import std.algorithm : min, max, clamp;

	real gravity(Point p1, Point p2)
	{
		return 16 / max(0, pow((p1.distance(p2)) / 4, 2));
	}

	foreach(ref p; particles)
	{
		Point f = Point(0, 0);
		// f.movePolar(uniform01() * 2 * PI, 1);
		// fx -= gravity(0, p.x) + gravity(600, p.x);
		// fy -= gravity(0, p.y) + gravity(600, p.y);
		Particle* nearest;
		foreach(ref p2; particles)
		{
			if (p == p2)
				continue;
			if(nearest is null || p.pos.distance(p2.pos) < p.pos.distance(nearest.pos))
				nearest = &p2;
				// fx += gravity(p.x, p2.x) * (p.type == p2.type ? 1 : -0.5);
				// fy += gravity(p.y, p2.y) * (p.type == p2.type ? 1 : -0.5);
				f.movePolar(p.pos.angleTo(p2.pos), gravity(p.pos, p2.pos));
		}
		if(p.pos.distance(nearest.pos) <= 8)
		{
			if ((nearest.type + 3 - p.type) % 3 == 1) {
				p.type = nearest.type;
			}
		}
		// p.x = clamp(p.x + fx, 0, 600);
		// p.y = clamp(p.y + fy, 0, 600);
		// p.pos.movePolar(5, 1);
		p.pos += f;
	}
}

void draw()
{
	sdlr.SDL_SetRenderDrawColor(0, 0, 0, 255);
	sdlr.SDL_RenderClear();

	foreach(p; particles)
	{
		switch(p.type)
		{
			case RPS.ROCK:
				sdlr.SDL_SetRenderDrawColor(0, 0, 255, 200);
				break;
			case RPS.PAPER:
				sdlr.SDL_SetRenderDrawColor(0, 255, 0, 200);
				break;
			case RPS.SCISSORS:
				sdlr.SDL_SetRenderDrawColor(255, 0, 0, 200);
				break;
			default:
				assert(0);
		}
		sdlr.SDL_RenderFillRect(new SDL_Rect(p.pos.x.to!int - 4, p.pos.y.to!int - 4, 8, 8));
	}

	sdlr.SDL_RenderPresent();
}

void pollEvents()
{
	SDL_Event event;
	while (SDL_PollEvent(&event))
	{
		switch (event.type)
		{
		case SDL_QUIT:
			quit();
			break;
		case SDL_KEYDOWN:
			onKeyDown(event.key);
			break;
		case SDL_KEYUP:
			onKeyUp(event.key);
			break;
		case SDL_TEXTINPUT:
			onTextInput(event.text);
			break;
		case SDL_MOUSEBUTTONDOWN:
			onMouseDown(event.button);
			break;
		case SDL_MOUSEBUTTONUP:
			onMouseUp(event.button);
			break;
		case SDL_MOUSEMOTION:
			onMouseMotion(event.motion);
			break;
		case SDL_MOUSEWHEEL:
			onMouseWheel(event.wheel);
			break;
		case SDL_WINDOWEVENT:
			onWindowEvent(event.window);
			break;
		default:
			writeln("Unhandled event: ", cast(SDL_EventType) event.type);
		}
	}
}

void quit()
{
	running = false;
}

void onKeyDown(SDL_KeyboardEvent e)
{
	keystates = SDL_GetKeyboardState(null);
	keymods = e.keysym.mod;
	switch (e.keysym.sym)
	{
	case SDLK_ESCAPE:
		quit();
		break;
	default:
	}
}

void onKeyUp(SDL_KeyboardEvent e)
{
	keystates = SDL_GetKeyboardState(null);
	keymods = e.keysym.mod;
	switch (e.keysym.sym)
	{
	default:
	}
}

void onMouseDown(SDL_MouseButtonEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
	switch (e.button)
	{
	case SDL_BUTTON_LEFT:
		mouseL = true;
		break;
	case SDL_BUTTON_MIDDLE:
		mouseM = true;
		break;
	case SDL_BUTTON_RIGHT:
		mouseR = true;
		break;
	case SDL_BUTTON_X1:
	case SDL_BUTTON_X2:
	default:
	}
}

void onTextInput(SDL_TextInputEvent e)
{

}

void onMouseUp(SDL_MouseButtonEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
	switch (e.button)
	{
	case SDL_BUTTON_LEFT:
		mouseL = false;
		break;
	case SDL_BUTTON_MIDDLE:
		mouseM = false;
		break;
	case SDL_BUTTON_RIGHT:
		mouseR = false;
		break;
	case SDL_BUTTON_X1:
	case SDL_BUTTON_X2:
	default:
	}
}

void onMouseMotion(SDL_MouseMotionEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
}

void onMouseWheel(SDL_MouseWheelEvent e)
{

}

void onWindowEvent(SDL_WindowEvent e)
{
	switch (e.event)
	{
	case SDL_WINDOWEVENT_SHOWN:
	case SDL_WINDOWEVENT_HIDDEN:
		break;
	case SDL_WINDOWEVENT_EXPOSED:
		draw();
		break;
	case SDL_WINDOWEVENT_MOVED:
		break;
	case SDL_WINDOWEVENT_RESIZED:
		windowW = e.data1;
		windowH = e.data2;
		init();
		break;
	case SDL_WINDOWEVENT_MINIMIZED:
	case SDL_WINDOWEVENT_MAXIMIZED:
	case SDL_WINDOWEVENT_ENTER:
	case SDL_WINDOWEVENT_LEAVE:
	case SDL_WINDOWEVENT_FOCUS_GAINED:
	case SDL_WINDOWEVENT_FOCUS_LOST:
	case SDL_WINDOWEVENT_CLOSE:
	default:
	}
}
