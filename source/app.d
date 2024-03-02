import std.stdio;
import etc.linux.memoryerror;
import bindbc.sdl;
import std.string;
import std.random;
import std.conv;
import std.math;
import std.datetime.stopwatch;

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
		return atan2(-(p2.y - this.y), p2.x - this.x);
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
	Point vel = Point(0, 0);
	Point vel_smooth = Point(0, 0);
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
ubyte* keystates;
ushort keymods;
Particle[] particles;

SDL_Texture* rock_tex;
SDL_Texture* paper_tex;
SDL_Texture* scissors_tex;

void main()
{
	version(DMD)
	registerMemoryErrorHandler();

	// writeln(sdlSupport);

	if (loadSDL() != sdlSupport)
		writeln("Error loading SDL library");

	if (loadSDLImage() < sdlImageSupport)
		writeln("Error loading SDL Image library");

	if (SDL_Init(SDL_INIT_VIDEO) < 0)
		throw new SDLException();

	if (IMG_Init(IMG_INIT_PNG) != IMG_INIT_PNG)
		throw new SDLException();

	scope (exit)
		SDL_Quit();

	windowW = 1200;
	windowH = 900;
	auto window = SDL_CreateWindow("SDL Application", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
		windowW, windowH, SDL_WINDOW_SHOWN);
	if (!window)
		throw new SDLException();

	sdlr = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);

	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
	// SDL_SetHint(SDL_HINT_RENDER_LINE_METHOD, "2");
	SDL_SetRenderDrawBlendMode(sdlr, SDL_BLENDMODE_BLEND);

	rock_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./rock.png"));
	paper_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./paper.png"));
	scissors_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./scissors.png"));
	if(rock_tex is null || paper_tex is null || scissors_tex is null) {
		throw new SDLException();
	}

	init();

	auto sw = StopWatch(AutoStart.yes);
	running = true;
	while (running)
	{
		sw.reset();
		pollEvents();
		tick();
		long tick_msecs = sw.peek.total!"msecs";
		sw.reset();
		draw();
		long draw_msecs = sw.peek.total!"msecs";
		writefln!"tick %d msecs, draw %d msecs"(tick_msecs, draw_msecs);
	}
}

void init()
{
	auto rnd = MinstdRand0();

	particles = [];
	foreach(i; 0..100)
	{
		particles ~= Particle(rnd.uniform!RPS, Point(uniform01() * windowW, uniform01() * windowH), Point(0, 0), Point(0, 0));
	}
}

void tick()
{
	import std.algorithm : min, max, clamp;

	real gravity(Point p1, Point p2)
	{
		return 2 / pow(max(4, p1.distance(p2)) / 4, 2);
	}

	foreach(ref p; particles)
	{
		Point f = Point(0, 0);
		f.movePolar(uniform01() * 2 * PI, uniform01() * 0.4);
		f.x += 8 / pow(p.pos.x / 4, 2) - 8 / pow((windowW - p.pos.x) / 4, 2);
		f.y += 8 / pow(p.pos.y / 4, 2) - 8 / pow((windowH - p.pos.y) / 4, 2);
		// f.y -= gravity(0, p.y) + gravity(600, p.y);
		Particle* nearest;
		real nearest_dist;
		foreach(ref p2; particles)
		{
			if (p == p2)
				continue;
			real dist = p.pos.distance(p2.pos);
			if(nearest is null || dist < nearest_dist) 
			{
				nearest = &p2;
				nearest_dist = dist;
			}
			// fx += gravity(p.x, p2.x) * (p.type == p2.type ? 1 : -0.5);
			// fy += gravity(p.y, p2.y) * (p.type == p2.type ? 1 : -0.5);
			// if(dist <= 300)
				f.movePolar(p.pos.angleTo(p2.pos), gravity(p.pos, p2.pos) * (p.type == p2.type ? -0.9 : 1));
		}
		if(p.pos.distance(nearest.pos) <= 16)
		{
			if ((nearest.type + 3 - p.type) % 3 == 1) {
				p.type = nearest.type;
			}
		}
		// p.pos.movePolar(5, 1);
		// f.movePolar(f.angle(Point(0,0)), 0.1);
		// f.rotate(1);
		p.vel += f * 0.9;
		p.vel *= 0.9;
		// p.vel.rotate(0.1);
		p.pos += p.vel;
		p.pos.x = clamp(p.pos.x, 2, windowW - 2);
		p.pos.y = clamp(p.pos.y, 2, windowH - 2);
		p.vel_smooth = p.vel_smooth * 0.95 + p.vel * 0.5;
	}
}

void draw()
{
	sdlr.SDL_SetRenderDrawColor(0, 0, 0, 255);
	sdlr.SDL_RenderClear();

	int nrock = 0;
	int npaper = 0;
	int nscissors = 0;

	foreach(p; particles)
	{
		SDL_Texture* tex;
		switch(p.type)
		{
			case RPS.ROCK:
				tex = rock_tex;
				sdlr.SDL_SetRenderDrawColor(0, 0, 255, 200);
				nrock++;
				break;
			case RPS.PAPER:
				tex = paper_tex;
				sdlr.SDL_SetRenderDrawColor(0, 255, 0, 200);
				npaper++;
				break;
			case RPS.SCISSORS:
				tex = scissors_tex;
				sdlr.SDL_SetRenderDrawColor(255, 0, 0, 200);
				nscissors++;
				break;
			default:
				assert(0);
		}
		// sdlr.SDL_RenderFillRectF(new SDL_FRect(p.pos.x - 4, p.pos.y - 4, 8, 8));
		sdlr.SDL_RenderCopyExF(tex, null, new SDL_FRect(p.pos.x - 8, p.pos.y - 8, 16, 16), p.vel_smooth.angleTo(Point(-1, 0)) * 180 / PI, null, 0);
		// sdlr.SDL_RenderCopyF(tex, null, new SDL_FRect(p.pos.x - 8, p.pos.y - 8, 16, 16));
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
